import CoreFoundation
import Foundation

struct CodexTokenRateEvent: Sendable {
    enum Kind: Sendable {
        case metadata(threadID: String, parentID: String?, internalReview: Bool)
        case context(turnID: String?, internalReview: Bool)
        case start(turnID: String?)
        case finish(turnID: String?)
        case output
        case toolStart(String)
        case toolEnd(String)
        case usage(total: Int, last: Int?, reasoning: Int?, cached: Bool)
        case request(id: String, turnID: String, output: Int, reasoning: Int?)
        case ownedBoundary
        case reset
    }
    let date: Date
    let threadID: String?
    let kind: Kind
}

/// 只把时间、标识符和用量传入测速状态，不保存聊天或工具正文。
final class CodexTokenRateEventDecoder {
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plain = ISO8601DateFormatter()

    func decode(_ line: Data) -> CodexTokenRateEvent? {
        guard line.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let outer = object["type"] as? String else { return nil }
        // 继承历史的分界本身不一定带时间，不能因此沿用父会话的测量窗口。
        if outer == "world_state" { return .init(date: .distantPast, threadID: nil, kind: .reset) }
        guard let stamp = object["timestamp"] as? String,
              let date = fractional.date(from: stamp) ?? plain.date(from: stamp) else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let threadID = Self.identifier(payload["thread_id"])?.lowercased()
        let kind = payload["type"] as? String
        func event(_ kind: CodexTokenRateEvent.Kind) -> CodexTokenRateEvent {
            .init(date: date, threadID: threadID, kind: kind)
        }
        if outer == "session_meta", let id = Self.identifier(payload["id"]) {
            let source = payload["source"] as? [String: Any]
            let subagent = (source?["subagent"] ?? source?["subAgent"]) as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            let parent = Self.identifier(payload["parent_thread_id"] ?? payload["parentThreadId"]
                ?? spawn?["parent_thread_id"] ?? spawn?["parentThreadId"])
            let role = (subagent?["other"] as? String)?.lowercased() ?? ""
            let review = source?["subagent"] as? String == "review" || subagent?["review"] != nil
                || ["guardian", "auto_review", "autoreview"].contains(role)
                || ["guardian_review", "auto_review", "autoreview"].contains(payload["thread_source"] as? String ?? "")
            return event(.metadata(threadID: id.lowercased(), parentID: parent?.lowercased(), internalReview: review))
        }
        if outer == "turn_context" {
            let model = (payload["model"] as? String)?.split(separator: "/").last ?? ""
            return event(.context(turnID: Self.identifier(payload["turn_id"]), internalReview: model.hasPrefix("codex-auto-review")))
        }
        if outer == "token_usage_record", let id = Self.identifier(payload["response_id"]),
           let turn = Self.identifier(payload["turn_id"]), threadID != nil,
           let usage = payload["usage"] as? [String: Any], let output = Self.counter(usage["output_tokens"]) {
            return event(.request(id: id, turnID: turn, output: output,
                                  reasoning: Self.counter(usage["reasoning_output_tokens"])))
        }
        if outer == "event_msg" {
            if ["task_started", "turn_started"].contains(kind ?? "") {
                return event(.start(turnID: Self.identifier(payload["turn_id"])))
            }
            if ["task_complete", "task_completed", "task_stopped", "task_failed", "task_cancelled",
                "turn_complete", "turn_completed", "turn_aborted", "turn_failed", "turn_cancelled"].contains(kind ?? "") {
                return event(.finish(turnID: Self.identifier(payload["turn_id"])))
            }
            if kind == "token_count", let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any], let output = Self.counter(total["output_tokens"]) {
                let last = info["last_token_usage"] as? [String: Any]
                return event(.usage(total: output, last: Self.counter(last?["output_tokens"]),
                                    reasoning: Self.counter(last?["reasoning_output_tokens"]),
                                    cached: payload["cached"] as? Bool == true || info["cached"] as? Bool == true))
            }
            if ["thread_settings_applied", "item_completed"].contains(kind ?? ""), threadID != nil {
                return event(.ownedBoundary)
            }
        }
        if outer == "response_item" {
            switch kind {
            case "function_call", "custom_tool_call":
                if let id = Self.identifier(payload["call_id"]) { return event(.toolStart(id)) }
            case "function_call_output", "custom_tool_call_output":
                if let id = Self.identifier(payload["call_id"]) { return event(.toolEnd(id)) }
            case "reasoning": return event(.output)
            case "message" where payload["role"] as? String == "assistant": return event(.output)
            default: break
            }
        }
        return nil
    }

    private static func counter(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, id.utf8.count <= 256 else { return nil }
        return id
    }
}

struct CodexTokenRateState: Sendable {
    private(set) var threadID: String?
    private(set) var parentThreadID: String?
    private var internalReview = false
    private var ignoringInheritedHistory = false
    private var turnID: String?
    private var retiredTurns: [String] = []
    private var observedStart = false
    private var latestEventAt: Date = .distantPast
    private var calls: Set<String> = []
    private var waiting = false
    private var finished = true
    private var meter = ResponsePerformanceMeter()
    private var fallback = GenerationRate()
    private var retained: (value: Double, date: Date, estimate: Bool)?
    private var cumulativeOutput: Int?
    private var settledFallbackThrough: Date?

    init(threadID: String? = nil) { self.threadID = threadID?.lowercased() }

    mutating func consume(_ event: CodexTokenRateEvent) {
        if case let .metadata(id, parent, review) = event.kind {
            if let threadID, threadID != id { ignoringInheritedHistory = true; return }
            threadID = id; parentThreadID = parent; internalReview = internalReview || review
            ignoringInheritedHistory = false
            return
        }
        guard let threadID else { return }
        if let owner = event.threadID, owner != threadID { return }
        if case .reset = event.kind {
            resetMeasurement(); ignoringInheritedHistory = false; return
        }
        if ignoringInheritedHistory {
            guard event.threadID == threadID else { return }
            ignoringInheritedHistory = false; resetMeasurement()
        }
        if case let .request(id, turn, output, reasoning) = event.kind {
            let previous = meter.latest
            meter.observeRequest(id: id, turn: turn, output: output, reasoning: reasoning, at: event.date)
            remember(at: event.date, preferSettled: meter.latest != previous); return
        }
        if case let .finish(id) = event.kind, id != nil, id != turnID { return }
        let previousPerformance = meter.latest
        guard event.date >= latestEventAt else { return }
        latestEventAt = event.date
        switch event.kind {
        case let .context(id, review):
            internalReview = internalReview || review
            if let id, id != turnID, !retiredTurns.contains(id) { start(id: id, at: event.date, observed: false) }
        case let .start(id):
            let identity = id ?? "\(threadID):\(event.date.timeIntervalSince1970)"
            guard !retiredTurns.contains(identity), identity != turnID || !observedStart else { return }
            start(id: identity, at: event.date, observed: true)
        case let .finish(id):
            guard let turnID, id == nil || id == turnID, !finished else { return }
            remember(at: event.date)
            finished = true; waiting = false; calls.removeAll(); meter.finish(); fallback.finish()
            retire(turnID)
        case .output:
            ensureTurn(at: event.date)
            meter.modelOutput(at: event.date, textDelta: false)
            waiting = false; fallback.setWaiting(false, at: event.date)
        case let .toolStart(id):
            guard !calls.contains(id), calls.count < 64 else { return }
            ensureTurn(at: event.date)
            meter.modelOutput(at: event.date, textDelta: false)
            calls.insert(id); waiting = true
            meter.setWaiting(true, at: event.date); fallback.setWaiting(true, at: event.date)
        case let .toolEnd(id):
            guard calls.remove(id) != nil else { return }
            if calls.isEmpty {
                let wasWaiting = waiting
                waiting = false; fallback.setWaiting(false, at: event.date)
                // 后台工具返回前若已有模型输出，返回事件不是下一次请求起点。
                if wasWaiting { meter.inputBoundary(at: event.date) }
            }
        case let .usage(total, last, reasoning, cached):
            guard turnID != nil, !finished else { return }
            if let previous = cumulativeOutput, total < previous {
                // 回退后的输出不能除以前一个计数域的请求窗口。
                meter.start(turnID: turnID, at: event.date, observed: false)
                fallback.start(); fallback.observe(total: total, at: event.date, cached: true)
                if waiting { fallback.setWaiting(true, at: event.date); meter.setWaiting(true, at: event.date) }
                retained = nil; settledFallbackThrough = nil; cumulativeOutput = total
                return
            }
            cumulativeOutput = total
            meter.observeRuntime(total: total, last: last, reasoning: reasoning, at: event.date, cached: cached)
            fallback.observe(total: total, at: event.date, cached: cached)
        default: break
        }
        remember(at: event.date, preferSettled: meter.latest != previousPerformance)
    }

    mutating func resetMeasurement() {
        turnID = nil; observedStart = false; calls.removeAll(); waiting = false; finished = true
        meter = ResponsePerformanceMeter(); fallback.start(); retained = nil
        cumulativeOutput = nil; settledFallbackThrough = nil
    }
    private mutating func start(id: String, at date: Date, observed: Bool) {
        if let old = turnID, old != id { retire(old) }
        turnID = id; observedStart = observed; finished = false; waiting = false; calls.removeAll()
        meter.start(turnID: id, at: date, observed: observed); fallback.start(); retained = nil
        cumulativeOutput = nil; settledFallbackThrough = nil
    }
    private mutating func ensureTurn(at date: Date) {
        if turnID == nil || finished { start(id: "observed:\(date.timeIntervalSince1970)", at: date, observed: false) }
    }
    private mutating func retire(_ id: String) {
        if !retiredTurns.contains(id) { retiredTurns.append(id) }
        if retiredTurns.count > 64 { retiredTurns.removeFirst(retiredTurns.count - 64) }
    }
    private mutating func remember(at date: Date, preferSettled: Bool = false) {
        let sample = meter.latest
        if preferSettled, let sample {
            // 同一 usage 即使延迟到达，也应采用其实际请求窗口，而非抵达时间的差分。
            retained = (sample.tokensPerSecond, sample.completedAt, false)
            settledFallbackThrough = date
            return
        }
        let estimate = fallback.estimate(at: date).flatMap {
            $0.reportedAt > (settledFallbackThrough ?? .distantPast) ? $0 : nil
        }
        let next: (value: Double, date: Date, estimate: Bool)?
        if let estimate, estimate.value > 0,
           sample == nil || estimate.reportedAt.timeIntervalSince(sample!.completedAt) > 2 {
            next = (estimate.value, estimate.reportedAt, true)
        } else if let sample {
            next = (sample.tokensPerSecond, sample.completedAt, false)
        } else { next = nil }
        guard let next else { return }
        if let retained, retained.date > next.date,
           !(retained.estimate && !next.estimate && retained.date.timeIntervalSince(next.date) <= 2) { return }
        retained = next
    }
    var sample: TokenRateTaskSample? {
        guard let threadID, let retained, retained.value.isFinite, retained.value > 0 else { return nil }
        return .init(threadID: threadID, parentThreadID: parentThreadID, value: retained.value,
                     measuredAt: retained.date, isEstimate: retained.estimate, isWaiting: waiting,
                     isFinished: finished, isInternalReview: internalReview)
    }
}
