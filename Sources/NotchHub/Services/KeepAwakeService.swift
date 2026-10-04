import Combine
import Foundation
import IOKit.pwr_mgt
import IOKit.ps

@MainActor protocol KeepAwakeAsserting: AnyObject {
    func acquire(display: Bool) throws -> UInt32
    func release(_ assertion: UInt32)
}

@MainActor private final class KeepAwakeAssertions: KeepAwakeAsserting {
    func acquire(display: Bool) throws -> UInt32 {
        var assertion = IOPMAssertionID(0)
        let type = display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NotchHub: пользователь включил режим «Не засыпать»" as CFString, &assertion)
        guard result == kIOReturnSuccess else {
            throw KeepAwakeFailure("macOS не разрешила включить режим «Не засыпать» (\(result)).")
        }
        return assertion
    }

    func release(_ assertion: UInt32) { IOPMAssertionRelease(assertion) }
}

@MainActor final class KeepAwakeService: ObservableObject {
    @Published var duration: KeepAwakeDuration = .halfHour
    @Published var keepDisplayAwake = false
    @Published var powerOnly = true
    /// Session-only opt-in: never persisted or automatically resumed on launch.
    @Published var allowClosedLid = false
    @Published private(set) var isActive = false
    @Published private(set) var deadline: Date?
    @Published private(set) var secondsRemaining: Int?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lidPhase: KeepAwakeLidPhase = .idle
    @Published private(set) var pendingRestoration = false

    private let assertions: KeepAwakeAsserting
    private let lid: KeepAwakeLidControlling
    private let power: () -> KeepAwakePower
    private let now: () -> Date
    private var systemAssertion: UInt32?
    private var displayAssertion: UInt32?
    private var monitor: Task<Void, Never>?
    private var sessionPowerOnly = true
    private var sessionClosedLid = false
    private var stopping = false

    convenience init() {
        self.init(assertions: KeepAwakeAssertions(), lid: KeepAwakeLidController(),
                  power: Self.currentPower, now: Date.init)
    }

    init(assertions: KeepAwakeAsserting, lid: KeepAwakeLidControlling,
         power: @escaping () -> KeepAwakePower, now: @escaping () -> Date) {
        self.assertions = assertions
        self.lid = lid
        self.power = power
        self.now = now
    }

    func start() {
        guard monitor == nil else { return }
        stopping = false
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    /// Stop releases IOKit assertions immediately. The independent privileged
    /// watchdog restores its setting and remains observed until completion.
    func stop() {
        stopping = true
        endSession()
        if !pendingRestoration {
            monitor?.cancel()
            monitor = nil
        }
    }

    func beginSession() {
        guard !isActive, !pendingRestoration else { return }
        let current = now()
        if let reason = KeepAwakePolicy.stopReason(deadline: nil, now: current,
                                                   power: power(), powerOnly: powerOnly) {
            statusMessage = reason
            return
        }
        let until = KeepAwakePolicy.deadline(duration: duration, closedLid: allowClosedLid, now: current)
        statusMessage = nil
        do {
            systemAssertion = try assertions.acquire(display: false)
            if keepDisplayAwake { displayAssertion = try assertions.acquire(display: true) }
            if allowClosedLid, let until { try lid.begin(deadline: until, powerOnly: powerOnly) }
            deadline = until
            sessionPowerOnly = powerOnly
            sessionClosedLid = allowClosedLid
            isActive = true
            secondsRemaining = until.map { max(0, Int($0.timeIntervalSince(current).rounded(.up))) }
            lidPhase = lid.phase
            start()
        } catch {
            releaseAssertions()
            statusMessage = error.localizedDescription
            lidPhase = lid.phase
        }
    }

    func endSession() {
        releaseAssertions()
        lid.stop()
        isActive = false
        deadline = nil
        secondsRemaining = nil
        lidPhase = lid.phase
        pendingRestoration = lid.pendingRestoration
    }

    /// Internal so tests can exercise expiration and battery transitions without
    /// creating assertions, timers, processes or administrator prompts.
    func refresh() async {
        if isActive {
            if let reason = KeepAwakePolicy.stopReason(deadline: deadline, now: now(),
                power: power(), powerOnly: sessionPowerOnly) {
                endSession()
                statusMessage = reason
            } else {
                secondsRemaining = deadline.map { max(0, Int($0.timeIntervalSince(now()).rounded(.up))) }
            }
        }
        await lid.refresh()
        lidPhase = lid.phase
        pendingRestoration = lid.pendingRestoration
        if sessionClosedLid || pendingRestoration, let message = lid.message { statusMessage = message }
        if isActive, sessionClosedLid, lid.phase == .restoring || lid.phase == .failed || lid.phase == .idle {
            endSession()
        }
        if stopping && !pendingRestoration {
            monitor?.cancel()
            monitor = nil
        }
    }

    var remainingTitle: String {
        guard let secondsRemaining else { return "До выключения" }
        let minutes = max(1, Int(ceil(Double(secondsRemaining) / 60)))
        if minutes < 60 { return "Ещё \(minutes) мин" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "Ещё \(hours) ч" : "Ещё \(hours) ч \(rest) мин"
    }

    private func releaseAssertions() {
        if let displayAssertion { assertions.release(displayAssertion) }
        if let systemAssertion { assertions.release(systemAssertion) }
        displayAssertion = nil
        systemAssertion = nil
    }

    private static func currentPower() -> KeepAwakePower {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return KeepAwakePower(external: nil, batteryPercent: nil)
        }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let external: Bool? = type == kIOPSACPowerValue ? true : (type == kIOPSBatteryPowerValue ? false : nil)
        var percent: Int?
        if let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = info[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                percent = max(0, min(100, current * 100 / maximum))
                break
            }
        }
        return KeepAwakePower(external: external, batteryPercent: percent)
    }
}
