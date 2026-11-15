import RenderAPI

/// What the autoscaling sheet edits and `PUT /services/{id}/autoscaling` takes.
///
/// The limits mirror what the live API rejects: at least one instance, a maximum no lower than the
/// minimum and no higher than 100 (more needs Render support), targets between 1 and 90 percent, and
/// at least one target while autoscaling is on. Checking them here turns a 400 after a round trip
/// into a disabled Save button with the reason under it.
struct AutoscalingSettings: Hashable {
    static let instanceRange = 1...100
    static let targetRange = 1...90

    var isEnabled: Bool
    var min: Int
    var max: Int
    var isCPUTargetEnabled: Bool
    var cpuPercent: Int
    var isMemoryTargetEnabled: Bool
    var memoryPercent: Int

    /// Starts from the service's saved settings, or from a sensible default for one that has none.
    /// A target that's off keeps a percentage anyway, because the API requires one either way.
    init(_ autoscaling: ServiceDetails.Autoscaling?, currentInstances: Int) {
        if let autoscaling {
            isEnabled = autoscaling.isEnabled
            min = autoscaling.min
            max = autoscaling.max
            isCPUTargetEnabled = autoscaling.cpuTarget != nil
            cpuPercent = autoscaling.cpuTarget ?? 70
            isMemoryTargetEnabled = autoscaling.memoryTarget != nil
            memoryPercent = autoscaling.memoryTarget ?? 70
        } else {
            isEnabled = true
            min = Swift.max(currentInstances, 1)
            max = Swift.min(Swift.max(currentInstances, 1) * 2, Self.instanceRange.upperBound)
            isCPUTargetEnabled = true
            cpuPercent = 70
            isMemoryTargetEnabled = false
            memoryPercent = 70
        }
    }

    init(
        isEnabled: Bool, min: Int, max: Int,
        cpuPercent: Int?, memoryPercent: Int?
    ) {
        self.isEnabled = isEnabled
        self.min = min
        self.max = max
        isCPUTargetEnabled = cpuPercent != nil
        self.cpuPercent = cpuPercent ?? 70
        isMemoryTargetEnabled = memoryPercent != nil
        self.memoryPercent = memoryPercent ?? 70
    }

    /// Why Save is disabled, or `nil` when the API should accept these settings.
    var validationMessage: String? {
        if !Self.instanceRange.contains(min) || !Self.instanceRange.contains(max) {
            return "Instance counts must be between 1 and 100."
        }
        if max < min {
            return "Maximum can't be lower than minimum."
        }
        if isCPUTargetEnabled && !Self.targetRange.contains(cpuPercent)
            || isMemoryTargetEnabled && !Self.targetRange.contains(memoryPercent) {
            return "Targets must be between 1% and 90%."
        }
        if isEnabled && !isCPUTargetEnabled && !isMemoryTargetEnabled {
            return "Turn on a CPU or memory target so Render knows when to scale."
        }
        return nil
    }

    /// One line for the confirmation dialog.
    var summary: String {
        guard isEnabled else {
            return "Turns autoscaling off and keeps these settings. The service keeps its current instance count."
        }
        let targets = [
            isCPUTargetEnabled ? "CPU \(cpuPercent)%" : nil,
            isMemoryTargetEnabled ? "memory \(memoryPercent)%" : nil,
        ].compactMap(\.self).joined(separator: " and ")
        if min == max {
            return "Holds \(min) instance\(min == 1 ? "" : "s"), targeting \(targets)."
        }
        return "Scales between \(min) and \(max) instances, targeting \(targets)."
    }

    var requestBody: Operations.AutoscaleService.Input.Body.JsonPayload {
        .init(
            enabled: isEnabled,
            min: min,
            max: max,
            criteria: .init(
                cpu: .init(enabled: isCPUTargetEnabled, percentage: cpuPercent),
                memory: .init(enabled: isMemoryTargetEnabled, percentage: memoryPercent)
            )
        )
    }
}
