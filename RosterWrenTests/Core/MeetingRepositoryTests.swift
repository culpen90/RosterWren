import Foundation
import XCTest
@testable import RosterWren

final class MeetingRepositoryTests: XCTestCase {
    func testCreatesUniquePrivateFoldersForConsecutiveSessions() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(rootDirectory: root)
        var roster = MeetingRoster(startedAt: Date(timeIntervalSince1970: 1_700_001_000))
        roster.observe(displayNames: ["Taylor"])

        let first = try await repository.createMeeting(for: roster)
        let second = try await repository.createMeeting(for: roster)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directoryURL.path))
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: first.directoryURL), 0o700)
        XCTAssertEqual(try permissions(of: second.directoryURL), 0o700)
    }

    func testExistingRootPermissionsArePreservedWhileSessionIsPrivate() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o750)],
            ofItemAtPath: root.path
        )

        let repository = MeetingRepository(rootDirectory: root)
        let session = try await repository.createMeeting(for: MeetingRoster())

        XCTAssertEqual(try permissions(of: root), 0o750)
        XCTAssertEqual(try permissions(of: session.directoryURL), 0o700)
    }

    func testCheckpointAndFinalizationWriteExpectedFilesAndPermissions() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(rootDirectory: root)
        let start = Date(timeIntervalSince1970: 1_700_002_000.125)
        var roster = MeetingRoster(title: "CSV safety", startedAt: start)
        roster.observe(
            displayNames: [
                "=SUM(1,2)",
                "+plus",
                "-minus",
                "@mention",
                " \t=hidden",
                "Ada, \"Ace\"\r\nLovelace",
                "Zoë"
            ],
            at: start
        )

        let session = try await repository.createMeeting(for: roster)
        let checkpoint = session.directoryURL.appendingPathComponent("meeting.json.inprogress")
        let csv = session.directoryURL.appendingPathComponent("participants.csv")
        let finalJSON = session.directoryURL.appendingPathComponent("meeting.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csv.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalJSON.path))
        XCTAssertEqual(try permissions(of: checkpoint), 0o600)
        XCTAssertEqual(try permissions(of: csv), 0o600)

        let checkpointText = try String(contentsOf: checkpoint, encoding: .utf8)
        XCTAssertTrue(checkpointText.contains("=SUM(1,2)"))
        XCTAssertFalse(checkpointText.contains("'=SUM(1,2)"))

        let csvText = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(csvText.hasSuffix("\r\n"))
        XCTAssertTrue(csvText.contains("\"'=SUM(1,2)\""))
        XCTAssertTrue(csvText.contains("'+plus"))
        XCTAssertTrue(csvText.contains("'-minus"))
        XCTAssertTrue(csvText.contains("'@mention"))
        XCTAssertTrue(csvText.contains("' \t=hidden"))
        XCTAssertTrue(csvText.contains("\"Ada, \"\"Ace\"\"\r\nLovelace\""))
        XCTAssertTrue(csvText.contains("2023-11-14T22:46:40.125Z"))

        roster.finish(at: start.addingTimeInterval(30))
        try await repository.finalize(roster, in: session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csv.path))
        XCTAssertEqual(try permissions(of: finalJSON), 0o600)
        XCTAssertEqual(try permissions(of: csv), 0o600)

        let recent = try await repository.recentExports()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].state, .finalized)
        XCTAssertEqual(recent[0].roster, roster)
    }

    func testCheckpointKeepsLeaversInCurrentCSVAndRecentListsInProgress() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(rootDirectory: root)
        let start = Date(timeIntervalSince1970: 1_700_003_000)
        var roster = MeetingRoster(startedAt: start)
        roster.observe(displayNames: ["Here", "Left"], at: start)
        let session = try await repository.createMeeting(for: roster)

        roster.observe(displayNames: ["Here"], at: start.addingTimeInterval(3))
        try await repository.checkpoint(roster, in: session)

        let csvURL = session.directoryURL.appendingPathComponent("participants.csv")
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        XCTAssertTrue(csv.contains("Here"))
        XCTAssertTrue(csv.contains("Left"))

        let recent = try await repository.recentExports(limit: 1)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].state, .inProgress)
        XCTAssertEqual(recent[0].roster.participants.count, 2)
        XCTAssertEqual(recent[0].roster.presentParticipants.map(\.displayName), ["Here"])
    }

    func testRepositoryRejectsCrossMeetingAndPostFinalizationWrites() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(rootDirectory: root)
        let firstRoster = MeetingRoster()
        let session = try await repository.createMeeting(for: firstRoster)

        do {
            try await repository.checkpoint(MeetingRoster(), in: session)
            XCTFail("Expected a meeting mismatch")
        } catch {
            XCTAssertEqual(error as? MeetingRepositoryError, .meetingMismatch)
        }

        try await repository.finalize(firstRoster, in: session)
        do {
            try await repository.checkpoint(firstRoster, in: session)
            XCTFail("Expected an already-finalized error")
        } catch {
            XCTAssertEqual(error as? MeetingRepositoryError, .alreadyFinalized)
        }
    }

    func testCheckpointRecoveryRebuildsStaleCSVWithoutPromoting() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(rootDirectory: root)
        let startedAt = Date(timeIntervalSince1970: 1_700_003_500)
        var roster = MeetingRoster(startedAt: startedAt)
        roster.observe(displayNames: ["Earlier"], at: startedAt)
        let session = try await repository.createMeeting(for: roster)

        let checkpoint = session.directoryURL.appendingPathComponent("meeting.json.inprogress")
        let csv = session.directoryURL.appendingPathComponent("participants.csv")
        let staleCSV = try Data(contentsOf: csv)

        roster.observe(
            displayNames: ["Earlier", "Newest checkpoint"],
            at: startedAt.addingTimeInterval(5)
        )
        try await repository.checkpoint(roster, in: session)
        try staleCSV.write(to: csv, options: .atomic)

        let listing = try await repository.recentExportListing()

        XCTAssertEqual(listing.warnings, [])
        XCTAssertEqual(listing.exports.count, 1)
        XCTAssertEqual(listing.exports[0].state, .inProgress)
        XCTAssertEqual(listing.exports[0].roster, roster)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains("Newest checkpoint"))
        XCTAssertEqual(try permissions(of: csv), 0o600)
    }

    func testMatchingCheckpointAndFinalJSONPromoteInterruptedFinalization() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(rootDirectory: root)
        let startedAt = Date(timeIntervalSince1970: 1_700_004_000)
        var roster = MeetingRoster(startedAt: startedAt)
        roster.observe(displayNames: ["Recovered"], at: startedAt)
        roster.finish(at: startedAt.addingTimeInterval(30))
        let session = try await repository.createMeeting(for: roster)

        let checkpoint = session.directoryURL.appendingPathComponent("meeting.json.inprogress")
        let finalJSON = session.directoryURL.appendingPathComponent("meeting.json")
        let csv = session.directoryURL.appendingPathComponent("participants.csv")
        try FileManager.default.copyItem(at: checkpoint, to: finalJSON)
        try FileManager.default.removeItem(at: csv)

        let listing = try await repository.recentExportListing()

        XCTAssertEqual(listing.warnings, [])
        XCTAssertEqual(listing.exports.count, 1)
        XCTAssertEqual(listing.exports[0].state, .finalized)
        XCTAssertEqual(listing.exports[0].roster, roster)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: csv.path))
        XCTAssertEqual(try permissions(of: csv), 0o600)
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains("Recovered"))
    }

    func testMismatchedCheckpointAndFinalJSONRemainInProgress() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(rootDirectory: root)
        let startedAt = Date(timeIntervalSince1970: 1_700_005_000)
        var roster = MeetingRoster(startedAt: startedAt)
        roster.observe(displayNames: ["First generation"], at: startedAt)
        let session = try await repository.createMeeting(for: roster)

        let checkpoint = session.directoryURL.appendingPathComponent("meeting.json.inprogress")
        let finalJSON = session.directoryURL.appendingPathComponent("meeting.json")
        let csv = session.directoryURL.appendingPathComponent("participants.csv")
        try FileManager.default.copyItem(at: checkpoint, to: finalJSON)

        roster.observe(
            displayNames: ["First generation", "Checkpoint only"],
            at: startedAt.addingTimeInterval(5)
        )
        try await repository.checkpoint(roster, in: session)

        let listing = try await repository.recentExportListing()

        XCTAssertEqual(listing.warnings, [])
        XCTAssertEqual(listing.exports.count, 1)
        XCTAssertEqual(listing.exports[0].state, .inProgress)
        XCTAssertEqual(listing.exports[0].roster, roster)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertNotEqual(try Data(contentsOf: checkpoint), try Data(contentsOf: finalJSON))
        XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains("Checkpoint only"))
    }

    func testCorruptExportDoesNotHideValidExports() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = MeetingRepository(rootDirectory: root)
        let startedAt = Date(timeIntervalSince1970: 1_700_006_000)
        var roster = MeetingRoster(startedAt: startedAt)
        roster.observe(displayNames: ["Readable"], at: startedAt)
        let validSession = try await repository.createMeeting(for: roster)
        try await repository.finalize(roster, in: validSession)

        let corruptDirectory = root.appendingPathComponent(
            "20231114T000000000Z--\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: corruptDirectory,
            withIntermediateDirectories: false
        )
        try Data("not valid JSON".utf8).write(
            to: corruptDirectory.appendingPathComponent("meeting.json")
        )

        let listing = try await repository.recentExportListing()

        XCTAssertEqual(listing.exports.map(\.id), [validSession.id])
        XCTAssertEqual(listing.exports[0].state, .finalized)
        XCTAssertEqual(listing.exports[0].roster, roster)
        XCTAssertEqual(listing.warnings.count, 1)
        XCTAssertTrue(listing.warnings[0].contains(corruptDirectory.lastPathComponent))
    }

    private func makeTemporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("RosterWrenTests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        return parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
