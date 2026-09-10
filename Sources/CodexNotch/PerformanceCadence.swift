import Foundation

struct RefreshEnvironment: Equatable, Sendable {
    let isLowPowerModeEnabled: Bool
    let isThermallyConstrained: Bool

    var isConstrained: Bool {
        isLowPowerModeEnabled || isThermallyConstrained
    }

    static var current: RefreshEnvironment {
        let processInfo = ProcessInfo.processInfo
        let thermalState = processInfo.thermalState
        return RefreshEnvironment(
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            isThermallyConstrained: thermalState == .serious || thermalState == .critical
        )
    }
}

enum PerformanceCadencePolicy {
    static let visibleInterval: TimeInterval = 5
    static let hiddenOptInInterval: TimeInterval = 60
    static let constrainedInterval: TimeInterval = 300

    static func interval(
        isVisible: Bool,
        samplingEnabled: Bool,
        environment: RefreshEnvironment
    ) -> TimeInterval? {
        guard isVisible || samplingEnabled else { return nil }
        if environment.isConstrained {
            return constrainedInterval
        }
        return isVisible ? visibleInterval : hiddenOptInInterval
    }

    static func timerTolerance(for interval: TimeInterval) -> TimeInterval {
        min(max(interval * 0.1, 1), 30)
    }
}

