import Foundation
import XCTest
@testable import RosterWren

@MainActor
final class AppModelTests: XCTestCase {
    func testMeetingNeedsTwoConfirmationsAndRevealIsConsumedOnce() async throws {
        let fixture = try makeFixture(consented: true, trusted: true)
        defer { fixture.cleanup() }

        fixture.source.snapshots = [
            snapshot(meeting: true, panel: false),
            snapshot(meeting: true, panel: false),
            snapshot(meeting: true, panel: true, names: ["Alex", "Alex"]),
            snapshot(meeting: true, panel: true, names: ["Alex", "Alex"])
        ]

        await fixture.model.runOnePoll()
        XCTAssertEqual(fixture.model.phase, .confirmingMeeting)
        XCTAssertFalse(fixture.model.hasActiveMeeting)

        await fixture.model.runOnePoll()
        XCTAssertEqual(fixture.model.phase, .capturing)
        XCTAssertTrue(fixture.model.hasActiveMeeting)

        await fixture.model.runOnePoll()
        XCTAssertEqual(fixture.model.currentNames, ["Alex", "Alex"])

        await fixture.model.runOnePoll()
        XCTAssertEqual(fixture.source.revealArguments, [false, false, true, false])
    }

    func testZoomQuitFinalizesTheActiveRoster() async throws {
        let fixture = try makeFixture(consented: true, trusted: true)
        defer { fixture.cleanup() }

        fixture.source.snapshots = [
            snapshot(meeting: true, panel: true, names: ["Avery", "Blair"]),
            snapshot(meeting: true, panel: true, names: ["Avery", "Blair"]),
            snapshot(zoomRunning: false)
        ]

        await fixture.model.runOnePoll()
        await fixture.model.runOnePoll()
        XCTAssertTrue(fixture.model.hasActiveMeeting)
        XCTAssertEqual(fixture.model.currentNames.count, 2)

        await fixture.model.runOnePoll()

        XCTAssertFalse(fixture.model.hasActiveMeeting)
        XCTAssertEqual(fixture.model.phase, .waitingForZoom)
        XCTAssertEqual(fixture.model.recentExports.count, 1)
        XCTAssertEqual(fixture.model.recentExports.first?.state, .finalized)
        XCTAssertEqual(fixture.model.recentExports.first?.roster.participants.count, 2)
    }

    func testNoConsentOrPermissionNeverReadsZoom() async throws {
        let noConsent = try makeFixture(consented: false, trusted: true)
        defer { noConsent.cleanup() }
        noConsent.source.snapshots = [snapshot(meeting: true, panel: true, names: ["Hidden"])]

        await noConsent.model.runOnePoll()

        XCTAssertEqual(noConsent.model.phase, .onboarding)
        XCTAssertEqual(noConsent.source.captureCallCount, 0)
        XCTAssertFalse(noConsent.source.promptArguments.contains(true))

        let noPermission = try makeFixture(consented: true, trusted: false)
        defer { noPermission.cleanup() }
        noPermission.source.snapshots = [snapshot(meeting: true, panel: true, names: ["Hidden"])]

        await noPermission.model.runOnePoll()

        XCTAssertEqual(noPermission.model.phase, .permissionRequired)
        XCTAssertEqual(noPermission.source.captureCallCount, 0)
        XCTAssertFalse(noPermission.source.promptArguments.contains(true))
    }

    func testRevealRetriesOnlyWhenNoActionReachedZoom() async throws {
        let clock = TestNow(Date(timeIntervalSince1970: 1_700_100_000))
        let fixture = try makeFixture(
            consented: true,
            trusted: true,
            now: { clock.value }
        )
        defer { fixture.cleanup() }

        fixture.source.snapshots = [
            snapshot(meeting: true, token: "meeting-a"),
            snapshot(meeting: true, token: "meeting-a"),
            snapshot(meeting: true, token: "meeting-a"),
            snapshot(meeting: true, token: "meeting-a"),
            snapshot(meeting: true, token: "meeting-a", revealAttempted: true),
            snapshot(meeting: true, panel: true, names: ["Alex"], token: "meeting-a")
        ]

        await fixture.model.runOnePoll()
        await fixture.model.runOnePoll()
        await fixture.model.runOnePoll()
        await fixture.model.runOnePoll()
        clock.advance(by: 5)
        await fixture.model.runOnePoll()
        await fixture.model.runOnePoll()

        XCTAssertEqual(
            fixture.source.revealArguments,
            [false, false, true, false, true, false]
        )
        XCTAssertEqual(fixture.model.currentNames, ["Alex"])
    }

    func testDistinctMeetingWindowFinalizesBeforeStartingNextMeeting() async throws {
        let fixture = try makeFixture(consented: true, trusted: true)
        defer { fixture.cleanup() }

        fixture.source.snapshots = [
            snapshot(meeting: true, panel: true, names: ["Meeting A"], token: "a"),
            snapshot(meeting: true, panel: true, names: ["Meeting A"], token: "a"),
            snapshot(meeting: true, panel: true, names: ["Meeting B"], token: "b"),
            snapshot(meeting: true, panel: true, names: ["Meeting B"], token: "b")
        ]

        for _ in 0..<4 {
            await fixture.model.runOnePoll()
        }

        XCTAssertTrue(fixture.model.hasActiveMeeting)
        XCTAssertEqual(fixture.model.currentNames, ["Meeting B"])
        let first = try XCTUnwrap(
            fixture.model.recentExports.first(where: { $0.state == .finalized })
        )
        XCTAssertEqual(first.roster.participants.map(\.displayName), ["Meeting A"])
        XCTAssertEqual(first.roster.endReason, .replacedByAnotherMeeting)
    }

    func testUnreliableScanRestartsContinuousMeetingEndGrace() async throws {
        let clock = TestNow(Date(timeIntervalSince1970: 1_700_200_000))
        let fixture = try makeFixture(
            consented: true,
            trusted: true,
            now: { clock.value }
        )
        defer { fixture.cleanup() }

        fixture.source.snapshots = [
            snapshot(meeting: true, panel: true, names: ["A"], token: "a"),
            snapshot(meeting: true, panel: true, names: ["A"], token: "a"),
            snapshot(),
            snapshot(reliable: false, warnings: ["Temporary AX failure"]),
            snapshot()
        ]

        await fixture.model.runOnePoll()
        await fixture.model.runOnePoll()
        await fixture.model.runOnePoll()
        XCTAssertEqual(fixture.model.phase, .ending(secondsRemaining: 15))

        clock.advance(by: 20)
        await fixture.model.runOnePoll()
        XCTAssertEqual(fixture.model.phase, .error("Temporary AX failure"))
        XCTAssertTrue(fixture.model.hasActiveMeeting)

        await fixture.model.runOnePoll()
        XCTAssertEqual(fixture.model.phase, .ending(secondsRemaining: 15))
        XCTAssertTrue(fixture.model.hasActiveMeeting)
    }

    func testPauseDiscardsAnInFlightCaptureResult() async throws {
        let fixture = try makeFixture(consented: true, trusted: true)
        defer { fixture.cleanup() }
        fixture.source.snapshots = [
            snapshot(meeting: true, token: "a"),
            snapshot(meeting: true, token: "a")
        ]

        await fixture.model.runOnePoll()
        fixture.source.suspendNextCapture = true
        let poll = Task { await fixture.model.runOnePoll() }
        for _ in 0..<100 where !fixture.source.hasSuspendedCapture {
            await Task.yield()
        }
        XCTAssertTrue(fixture.source.hasSuspendedCapture)

        fixture.model.pauseAndSave()
        fixture.model.resume()
        XCTAssertFalse(fixture.model.captureEnabled)
        XCTAssertFalse(fixture.model.canResume)
        fixture.source.resumeSuspendedCapture()
        await poll.value
        for _ in 0..<20 where fixture.model.phase != .paused {
            await Task.yield()
        }

        XCTAssertEqual(fixture.model.phase, .paused)
        XCTAssertFalse(fixture.model.hasActiveMeeting)
        XCTAssertTrue(fixture.model.currentNames.isEmpty)
        XCTAssertTrue(fixture.model.canResume)
    }

    func testTerminationAwaitsAnInFlightPauseTransition() async throws {
        let fixture = try makeFixture(consented: true, trusted: true)
        defer { fixture.cleanup() }
        fixture.source.snapshots = [
            snapshot(meeting: true, panel: true, names: ["Saved"], token: "a"),
            snapshot(meeting: true, panel: true, names: ["Saved"], token: "a"),
            snapshot(meeting: true, panel: false, token: "a")
        ]
        await fixture.model.runOnePoll()
        await fixture.model.runOnePoll()

        fixture.source.suspendNextCapture = true
        fixture.model.openParticipantsNow()
        for _ in 0..<100 where !fixture.source.hasSuspendedCapture {
            await Task.yield()
        }
        XCTAssertTrue(fixture.source.hasSuspendedCapture)

        fixture.model.pauseAndSave()
        let termination = Task { await fixture.model.prepareForTermination() }
        await Task.yield()
        XCTAssertTrue(fixture.model.isPausing)

        fixture.source.resumeSuspendedCapture()
        let shouldTerminate = await termination.value
        XCTAssertTrue(shouldTerminate)
        XCTAssertFalse(fixture.model.hasActiveMeeting)
        XCTAssertEqual(fixture.model.phase, .paused)
        XCTAssertEqual(fixture.model.recentExports.first?.state, .finalized)
        XCTAssertEqual(
            fixture.model.recentExports.first?.roster.endReason,
            .pausedByUser
        )
    }
}

@MainActor
private extension AppModelTests {
    struct Fixture {
        let model: AppModel
        let source: FakeZoomSource
        let defaults: UserDefaults
        let suiteName: String
        let rootURL: URL

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func makeFixture(
        consented: Bool,
        trusted: Bool,
        now: @escaping () -> Date = Date.init
    ) throws -> Fixture {
        let suiteName = "RosterWrenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            consented ? AppModel.consentVersion : 0,
            forKey: "privacyConsentVersion"
        )
        defaults.set(true, forKey: "captureEnabled")
        defaults.set(true, forKey: "autoRevealParticipants")

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RosterWren-AppModelTests-\(UUID().uuidString)", isDirectory: true)
        defaults.set(rootURL.path, forKey: "saveFolderPath")

        let source = FakeZoomSource(trusted: trusted)
        let model = AppModel(
            defaults: defaults,
            zoom: source,
            startsPolling: false,
            now: now
        )
        return Fixture(
            model: model,
            source: source,
            defaults: defaults,
            suiteName: suiteName,
            rootURL: rootURL
        )
    }

    func snapshot(
        zoomRunning: Bool = true,
        meeting: Bool = false,
        panel: Bool = false,
        names: [String] = [],
        token: String? = nil,
        revealAttempted: Bool = false,
        reliable: Bool = true,
        warnings: [String] = []
    ) -> ZoomCaptureSnapshot {
        ZoomCaptureSnapshot(
            zoomRunning: zoomRunning,
            version: zoomRunning ? "7.1.0" : nil,
            meetingDetected: meeting,
            panelDetected: panel,
            names: names,
            revealAttempted: revealAttempted,
            scanTruncated: false,
            warnings: warnings,
            meetingToken: token,
            isReliable: reliable
        )
    }
}

@MainActor
private final class TestNow {
    private(set) var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func advance(by interval: TimeInterval) {
        value = value.addingTimeInterval(interval)
    }
}

@MainActor
private final class FakeZoomSource: ZoomCaptureSource {
    var trusted: Bool
    var snapshots: [ZoomCaptureSnapshot] = []
    private(set) var promptArguments: [Bool] = []
    private(set) var revealArguments: [Bool] = []
    private(set) var captureCallCount = 0
    var suspendNextCapture = false
    private(set) var hasSuspendedCapture = false
    private var suspendedCaptureContinuation: CheckedContinuation<Void, Never>?

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func requestAccessibilityAccess(prompt: Bool) -> Bool {
        promptArguments.append(prompt)
        return trusted
    }

    func captureParticipants(allowReveal: Bool) async -> ZoomCaptureSnapshot {
        captureCallCount += 1
        revealArguments.append(allowReveal)
        if suspendNextCapture {
            suspendNextCapture = false
            hasSuspendedCapture = true
            await withCheckedContinuation { continuation in
                suspendedCaptureContinuation = continuation
            }
            hasSuspendedCapture = false
        }
        guard !snapshots.isEmpty else {
            return ZoomCaptureSnapshot(
                zoomRunning: false,
                version: nil,
                meetingDetected: false,
                panelDetected: false,
                names: [],
                revealAttempted: false,
                scanTruncated: false,
                warnings: []
            )
        }
        return snapshots.removeFirst()
    }

    func resumeSuspendedCapture() {
        suspendedCaptureContinuation?.resume()
        suspendedCaptureContinuation = nil
    }
}
