import Foundation
import Markdown

enum TaskProgressParser {
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumTasks = 5_000
    static let maximumDocuments = 16

    static func parse(_ source: String, scope: TaskProgressScope = .document) throws -> TaskProgressTasks {
        guard source.utf8.count <= maximumBytes else { throw TaskProgressError.invalid("文档超过 2 MiB 限制。") }
        let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
        guard lineCount <= 50_000 else { throw TaskProgressError.invalid("文档超过 50000 行限制。") }
        let document = Document(parsing: source)
        let sections = try sections(in: document, lastLine: lineCount)
        let range: ClosedRange<Int>
        switch scope {
        case .document: range = 1...max(1, lineCount)
        case .section:
            guard let selected = sections.first(where: { $0.scope == scope }) else { throw TaskProgressError.scopeMissing }
            range = selected.line...max(selected.line, selected.endLine)
        }
        var items: [TaskProgressItem] = []
        var diagnostics: [String] = []
        func add(_ item: TaskProgressItem) throws {
            guard items.count < maximumTasks else { throw TaskProgressError.invalid("叶子任务超过 5000 项限制。") }
            items.append(item)
        }
        func headingGroups(_ line: Int) -> [String] {
            guard let section = sections.last(where: { $0.line <= line }), case .section(let path) = section.scope else { return [] }
            return path.map(\.title)
        }
        func walk(_ node: any Markup, groups: [String], depth: Int) throws {
            guard depth <= 64 else { throw TaskProgressError.invalid("文档嵌套过深。") }
            if excluded(node) { return }
            var nextGroups = groups
            if let table = node as? Markdown.Table {
                for row in table.body.rows {
                    let rowChildren = Array(row.children)
                    guard let line = row.range?.lowerBound.line, range.contains(line),
                          let first = rowChildren.first, Array(first.children).first is Markdown.Text else { continue }
                    let cells = row.children.map(plainText)
                    guard let cell = cells.first, let match = match(#"^\s*\[([ xX])\](?:\s+(.*))?\s*$"#, cell) else { continue }
                    let own = match.count > 2 ? match[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let title = own.isEmpty ? (cells.dropFirst().first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "(无标题任务)") : own
                    let checked = match[1].lowercased() == "x"
                    let state = explicitState(([own] + Array(cells.dropFirst())).flatMap { $0.components(separatedBy: "\n") }, checked: checked)
                    try add(TaskProgressItem(id: "table:\(line)", title: stripTaskID(title), checked: checked, line: line,
                                             groups: headingGroups(line), status: state.status, conflict: state.conflict))
                }
                return
            }
            if let item = node as? ListItem {
                let firstParagraph = item.children.first(where: { $0 is Paragraph })
                let firstLine = firstParagraph.map(plainText)?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = firstLine.isEmpty ? "(无标题任务)" : firstLine
                let descendants = try taskDescendants(item, depth: depth)
                if !descendants.isEmpty {
                    nextGroups = groups + [title]
                    if item.checkbox == .checked, descendants.contains(where: { $0.checkbox == .unchecked }) {
                        diagnostics.append("第 \(item.range?.lowerBound.line ?? 0) 行父项已勾选，但子项未全部勾选。")
                    }
                } else if let checkbox = item.checkbox, let line = item.range?.lowerBound.line, range.contains(line) {
                    var lines: [String] = []
                    for child in item.children {
                        if child is Paragraph { lines += plainText(child).components(separatedBy: "\n") }
                        if child is UnorderedList || child is OrderedList {
                            for detail in child.children {
                                guard let detail = detail as? ListItem, detail.checkbox == nil else { continue }
                                for paragraph in detail.children where paragraph is Paragraph {
                                    lines += plainText(paragraph).components(separatedBy: "\n")
                                }
                            }
                        }
                    }
                    let state = explicitState(lines, checked: checkbox == .checked)
                    try add(TaskProgressItem(id: "list:\(line)", title: stripTaskID(title), checked: checkbox == .checked,
                                             line: line, groups: headingGroups(line) + groups, status: state.status, conflict: state.conflict))
                }
            }
            for child in node.children { try walk(child, groups: nextGroups, depth: depth + 1) }
        }
        try walk(document, groups: [], depth: 0)
        return TaskProgressTasks(items: items, sections: sections, diagnostics: diagnostics)
    }

    private static func excluded(_ node: any Markup) -> Bool { node is BlockQuote || node is CodeBlock || node is HTMLBlock }

    private static func taskDescendants(_ node: any Markup, depth: Int) throws -> [ListItem] {
        guard depth <= 64 else { throw TaskProgressError.invalid("文档嵌套过深。") }
        if excluded(node) { return [] }
        var result: [ListItem] = []
        for child in node.children {
            if let item = child as? ListItem, item.checkbox != nil { result.append(item) }
            result += try taskDescendants(child, depth: depth + 1)
        }
        return result
    }

    private static func plainText(_ node: any Markup) -> String {
        if node is InlineHTML || node is HTMLBlock { return "" }
        if let text = node as? Markdown.Text { return text.string }
        if let code = node as? InlineCode { return code.code }
        if node is SoftBreak || node is LineBreak { return "\n" }
        return node.children.map(plainText).joined()
    }

    private struct HeadingEntry {
        let depth: Int
        let title: String
        let line: Int
        var endLine: Int
        let parent: Int?
        let siblingKey: String
        let ordinal: Int
    }

    private static func sections(in document: Document, lastLine: Int) throws -> [TaskProgressSection] {
        var entries: [HeadingEntry] = []
        var stack: [Int] = []
        var siblingCounts: [String: Int] = [:]
        for node in document.children {
            guard let heading = node as? Heading, let line = heading.range?.lowerBound.line else { continue }
            let title = plainText(heading).isEmpty ? "(空标题)" : plainText(heading)
            guard title.count <= 512, entries.count < 10_000 else { throw TaskProgressError.invalid("章节数量或标题长度超过限制。") }
            while let last = stack.last, entries[last].depth >= heading.level {
                entries[last].endLine = line - 1
                stack.removeLast()
            }
            let parent = stack.last
            let key = "\(parent ?? -1)|\(heading.level)|\(title)"
            let ordinal = (siblingCounts[key] ?? 0) + 1
            siblingCounts[key] = ordinal
            entries.append(HeadingEntry(depth: heading.level, title: title, line: line, endLine: lastLine,
                                        parent: parent, siblingKey: key, ordinal: ordinal))
            stack.append(entries.count - 1)
        }
        return entries.indices.map { index in
            var path: [TaskProgressHeading] = []
            var current: Int? = index
            while let position = current {
                let entry = entries[position]
                path.insert(TaskProgressHeading(depth: entry.depth, title: entry.title, ordinal: entry.ordinal,
                                                total: siblingCounts[entry.siblingKey] ?? 1), at: 0)
                current = entry.parent
            }
            return TaskProgressSection(scope: .section(path), line: entries[index].line, endLine: entries[index].endLine)
        }
    }

    private static func match(_ pattern: String, _ value: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options),
              let result = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            guard let range = Range(result.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }

    private static func stripTaskID(_ title: String) -> String {
        guard let result = match(#"^([A-Za-z]+\d+(?:[._-][A-Za-z0-9]+)*)(?:\s*[：:]\s*|\s+)"#, title) else { return title }
        let shortened = String(title.dropFirst(result[0].count))
        return shortened.isEmpty ? title : shortened
    }

    private static func explicitState(_ lines: [String], checked: Bool) -> (status: String?, conflict: Bool) {
        let values = Set(lines.compactMap { match(#"^\s*(?:状态|Status)\s*[：:]\s*(.+?)\s*$"#, $0, options: .caseInsensitive)?.last?.lowercased() })
        if values.count > 1 { return (nil, true) }
        let names = ["进行中": "进行中", "in_progress": "进行中", "验证中": "验证中", "validating": "验证中", "阻塞": "阻塞", "blocked": "阻塞"]
        let status = values.first.flatMap { names[$0] }
        return (status, checked && status != nil)
    }
}
