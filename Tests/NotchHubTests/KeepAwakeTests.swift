import XCTest
@testable import NotchHub

final class KeepAwakePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClosedLidHasAnIndependentHardDeadline() {
        XCTAssertNil(KeepAwakePolicy.deadline(duration: .indefinitely, closedLid: false, now: now))
        XCTAssertEqual(KeepAwakePolicy.deadline(duration: .indefinitely, closedLid: true, now: now),
                       now.addingTimeInterval(8 * 3600))
        XCTAssertEqual(KeepAwakePolicy.deadline(duration: .halfHour, closedLid: true, now: now),
                       now.addingTimeInterval(1800))
    }

    func testPowerPolicyFailsClosedForRequiredUnknownPowerAndProtectsBattery() {
        XCTAssertNotNil(KeepAwakePolicy.stopReason(deadline: nil, now: now,
            power: KeepAwakePower(external: nil, batteryPercent: nil), powerOnly: true))
        XCTAssertNotNil(KeepAwakePolicy.stopReason(deadline: nil, now: now,
            power: KeepAwakePower(external: false, batteryPercent: 15), powerOnly: false))
        XCTAssertNil(KeepAwakePolicy.stopReason(deadline: nil, now: now,
            power: KeepAwakePower(external: false, batteryPercent: 16), powerOnly: false))
        XCTAssertNil(KeepAwakePolicy.stopReason(deadline: nil, now: now,
            power: KeepAwakePower(external: true, batteryPercent: 5), powerOnly: true))
        XCTAssertNotNil(KeepAwakePolicy.stopReason(deadline: now, now: now,
            power: KeepAwakePower(external: true, batteryPercent: 100), powerOnly: false))
    }

    func testWatchdogRejectsInjectionInvalidIdentityAndUnboundedLifetime() {
        let birth = "Sun Oct 4 12:00:00 2026"
        func spec(app: Int32 = 22, lease: Int32 = 23, started: String = "Sun Oct 4 12:00:00 2026",
                  deadline: Int = 1_800_000_030) -> KeepAwakeWatchdog {
            KeepAwakeWatchdog(appPID: app, leasePID: lease, appStarted: started,
                             leaseStarted: birth, deadline: deadline, powerOnly: true)
        }
        XCTAssertThrowsError(try spec(app: 1).script(now: 1_800_000_000))
        XCTAssertThrowsError(try spec(app: 23).script(now: 1_800_000_000))
        XCTAssertThrowsError(try spec(started: "'; touch /tmp/unwanted; '").script(now: 1_800_000_000))
        XCTAssertThrowsError(try spec(started: "x\ny").script(now: 1_800_000_000))
        XCTAssertThrowsError(try spec(deadline: 1_800_000_000).script(now: 1_800_000_000))
        XCTAssertThrowsError(try spec(deadline: 1_800_028_801).script(now: 1_800_000_000))
        XCTAssertNoThrow(try spec().script(now: 1_800_000_000))
    }

    func testAuthorizationWrapsTheScriptAndOutlivesMaximumSession() throws {
        let script = try KeepAwakeWatchdog(appPID: 22, leasePID: 23,
            appStarted: "Sun Oct 4 12:00:00 2026", leaseStarted: "Sun Oct 4 12:00:00 2026",
            deadline: 1_800_000_030, powerOnly: true).script(now: 1_800_000_000)
        let appleScript = KeepAwakeWatchdog.appleScript(for: script)
        XCTAssertTrue(appleScript.contains("with administrator privileges"))
        XCTAssertTrue(appleScript.hasPrefix("with timeout of 29400 seconds"))
        XCTAssertTrue(appleScript.contains("\\\"$app\\\""))
    }
}

@MainActor private final class FakeAwakeAssertions: KeepAwakeAsserting {
    var acquired: [Bool] = []
    var released: [UInt32] = []
    var failDisplay = false
    var onRelease: (() -> Void)?
    func acquire(display: Bool) throws -> UInt32 {
        if display && failDisplay { throw KeepAwakeFailure("test failure") }
        acquired.append(display)
        return UInt32(acquired.count)
    }
    func release(_ assertion: UInt32) {
        released.append(assertion)
        onRelease?()
    }
}

@MainActor private final class FakeAwakeLid: KeepAwakeLidControlling {
    var phase: KeepAwakeLidPhase = .idle
    var message: String?
    var pendingRestoration: Bool { phase == .restoring }
    var began: Date?
    var stopped = 0
    var onStop: (() -> Void)?
    func begin(deadline: Date, powerOnly: Bool) throws { began = deadline; phase = .authorizing }
    func stop() {
        guard began != nil else { return }
        stopped += 1
        phase = .restoring
        onStop?()
    }
    func refresh() async {}
}

final class KeepAwakeSessionTests: XCTestCase {
    @MainActor
    func testOrdinarySessionReleasesBothAssertionsOnStopWithoutAdministrator() async {
        let assertions = FakeAwakeAssertions(), lid = FakeAwakeLid()
        let service = KeepAwakeService(assertions: assertions, lid: lid,
            power: { KeepAwakePower(external: true, batteryPercent: nil) }, now: Date.init)
        service.keepDisplayAwake = true
        service.duration = .indefinitely
        service.beginSession()
        XCTAssertTrue(service.isActive)
        XCTAssertNil(service.deadline)
        XCTAssertNil(lid.began)
        service.stop()
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(assertions.acquired, [false, true])
        XCTAssertEqual(assertions.released, [2, 1])
        service.stop()
        XCTAssertEqual(assertions.released, [2, 1])
    }

    @MainActor
    func testFailedDisplayAssertionRollsBackSystemAssertion() async {
        let assertions = FakeAwakeAssertions(), lid = FakeAwakeLid()
        assertions.failDisplay = true
        let service = KeepAwakeService(assertions: assertions, lid: lid,
            power: { KeepAwakePower(external: true, batteryPercent: nil) }, now: Date.init)
        service.keepDisplayAwake = true
        service.allowClosedLid = true
        service.beginSession()
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(assertions.released, [1])
        XCTAssertNil(lid.began)
        XCTAssertNotNil(service.statusMessage)
    }

    @MainActor
    func testLowBatteryReleasesAssertionBeforeLidLeaseAndWaitsForRestoration() async {
        let assertions = FakeAwakeAssertions(), lid = FakeAwakeLid()
        var power = KeepAwakePower(external: false, batteryPercent: 80)
        let service = KeepAwakeService(assertions: assertions, lid: lid, power: { power }, now: Date.init)
        defer { service.stop() }
        service.powerOnly = false
        service.allowClosedLid = true
        lid.onStop = { XCTAssertEqual(assertions.released, [1]) }
        service.beginSession()
        XCTAssertTrue(service.isActive)
        power.batteryPercent = 15
        await service.refresh()
        XCTAssertFalse(service.isActive)
        XCTAssertTrue(service.pendingRestoration)
        let count = assertions.acquired.count
        service.beginSession()
        XCTAssertEqual(assertions.acquired.count, count)
        lid.phase = .idle
        await service.refresh()
        XCTAssertFalse(service.pendingRestoration)
    }

    @MainActor
    func testExpirationAndUnpluggingStopTheirOwnSession() async {
        let assertions = FakeAwakeAssertions(), lid = FakeAwakeLid()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var power = KeepAwakePower(external: true, batteryPercent: 70)
        let service = KeepAwakeService(assertions: assertions, lid: lid, power: { power }, now: { clock })
        defer { service.stop() }
        service.beginSession()
        clock = clock.addingTimeInterval(1800)
        await service.refresh()
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(assertions.released, [1])
        service.beginSession()
        power.external = false
        await service.refresh()
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(assertions.released, [1, 2])
    }
}
