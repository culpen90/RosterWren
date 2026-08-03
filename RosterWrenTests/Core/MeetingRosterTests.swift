import Foundation
import XCTest
@testable import RosterWren

final class MeetingRosterTests: XCTestCase {
    func testDuplicateNamesRemainDistinctMultisetOccurrences() {
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(5)
        var roster = MeetingRoster(startedAt: firstDate)

        roster.observe(displayNames: ["Alex", " alex ", "ALEX"], at: firstDate)

        XCTAssertEqual(roster.participants.count, 3)
        XCTAssertEqual(Set(roster.participants.map(\.id)).count, 3)
        XCTAssertTrue(roster.participants.allSatisfy(\.isPresent))

        roster.observe(displayNames: ["ALEX", "Alex"], at: secondDate)

        XCTAssertEqual(roster.participants.count, 3)
        XCTAssertEqual(roster.presentParticipants.count, 2)
        XCTAssertEqual(roster.participants.map(\.observationCount).reduce(0, +), 5)
        XCTAssertEqual(roster.observationCount, 2)
    }

    func testLeaversAreRetainedAndRenameIsNotInferred() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        var roster = MeetingRoster(startedAt: start)
        roster.observe(displayNames: ["Alice", "Bob"], at: start)

        let bobID = try XCTUnwrap(
            roster.participants.first(where: { $0.displayName == "Bob" })?.id
        )
        roster.observe(displayNames: ["Alice"], at: start.addingTimeInterval(10))

        let retainedBob = try XCTUnwrap(roster.participants.first(where: { $0.id == bobID }))
        XCTAssertFalse(retainedBob.isPresent)
        XCTAssertEqual(retainedBob.lastSeen, start)
        XCTAssertEqual(retainedBob.observationCount, 1)

        roster.observe(displayNames: ["Alicia"], at: start.addingTimeInterval(20))

        XCTAssertEqual(roster.participants.count, 3)
        XCTAssertEqual(roster.presentParticipants.map(\.displayName), ["Alicia"])
        XCTAssertEqual(
            roster.participants.first(where: { $0.displayName == "Alice" })?.observationCount,
            2
        )
    }

    func testNormalizationIsNFCWhitespaceAndCaseInsensitiveOnly() throws {
        XCTAssertEqual(
            ParticipantNameNormalization.normalized("  Jose\u{301}\t Smith  "),
            "José Smith"
        )

        let start = Date(timeIntervalSince1970: 1_700_000_200)
        var roster = MeetingRoster(startedAt: start)
        roster.observe(displayNames: ["  Jose\u{301}\t Smith  "], at: start)
        roster.observe(displayNames: ["JOSÉ Smith"], at: start.addingTimeInterval(1))

        XCTAssertEqual(roster.participants.count, 1)
        XCTAssertEqual(roster.participants[0].displayName, "JOSÉ Smith")
        XCTAssertEqual(roster.participants[0].observationCount, 2)

        // Diacritics are significant; only canonical composition is normalized.
        roster.observe(displayNames: ["Jose Smith"], at: start.addingTimeInterval(2))
        XCTAssertEqual(roster.participants.count, 2)
        XCTAssertEqual(roster.presentParticipants.map(\.displayName), ["Jose Smith"])
    }

    func testModelsAreCodableAndSendableAndJSONKeepsRawDisplayName() throws {
        let rawName = "=SUM(1, 2)"
        var roster = MeetingRoster(title: "Weekly sync", zoomVersion: "7.1.0")
        roster.observe(displayNames: [rawName])
        roster.recordCaptureStatus(
            zoomVersion: "7.1.1",
            participantPanelObserved: true,
            scanWasTruncated: true,
            warnings: ["Visible rows may be incomplete."]
        )
        roster.finish(reason: .pausedByUser)

        requireSendable(roster)
        requireSendable(roster.participants[0])

        let data = try JSONEncoder().encode(roster)
        let decoded = try JSONDecoder().decode(MeetingRoster.self, from: data)
        XCTAssertEqual(decoded, roster)
        XCTAssertEqual(decoded.participants[0].displayName, rawName)
        XCTAssertEqual(decoded.captureSource, .zoomAccessibility)
        XCTAssertEqual(decoded.zoomVersion, "7.1.1")
        XCTAssertTrue(decoded.participantPanelObserved)
        XCTAssertTrue(decoded.scanWasTruncated)
        XCTAssertEqual(decoded.endReason, .pausedByUser)
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
