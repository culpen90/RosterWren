import Foundation

public actor MeetingRepository {
    public static var defaultRootDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("RosterWren", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    public let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL = MeetingRepository.defaultRootDirectory) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = FileManager()
    }

    /// Creates a new, independently identified export folder and immediately
    /// writes its first recovery checkpoint.
    public func createMeeting(for roster: MeetingRoster) throws -> MeetingSession {
        try ensurePrivateDirectory(rootDirectory)

        var session: MeetingSession
        repeat {
            let sessionID = UUID()
            let directory = rootDirectory.appendingPathComponent(
                Self.folderName(startedAt: roster.startedAt, sessionID: sessionID),
                isDirectory: true
            )
            session = MeetingSession(
                id: sessionID,
                meetingID: roster.id,
                directoryURL: directory,
                createdAt: Date()
            )
        } while fileManager.fileExists(atPath: session.directoryURL.path)

        try ensurePrivateDirectory(session.directoryURL)

        do {
            try writeCheckpoint(roster, in: session)
            return session
        } catch {
            // A failed initial checkpoint is not a usable meeting session.
            try? fileManager.removeItem(at: session.directoryURL)
            throw error
        }
    }

    /// Atomically replaces both recovery files for an active meeting.
    public func checkpoint(_ roster: MeetingRoster, in session: MeetingSession) throws {
        try validate(roster, session: session)

        let finalJSON = session.directoryURL.appendingPathComponent(Self.finalJSONName)
        let inProgressJSON = session.directoryURL.appendingPathComponent(Self.inProgressJSONName)
        if fileManager.fileExists(atPath: finalJSON.path),
           !fileManager.fileExists(atPath: inProgressJSON.path) {
            throw MeetingRepositoryError.alreadyFinalized
        }

        try writeCheckpoint(roster, in: session)
    }

    /// Writes the final JSON and CSV atomically, then removes the recovery
    /// checkpoint. If either final write fails, the checkpoint is retained.
    public func finalize(_ roster: MeetingRoster, in session: MeetingSession) throws {
        try validate(roster, session: session)

        let inProgressJSON = session.directoryURL.appendingPathComponent(Self.inProgressJSONName)
        let finalJSON = session.directoryURL.appendingPathComponent(Self.finalJSONName)

        if !fileManager.fileExists(atPath: inProgressJSON.path),
           fileManager.fileExists(atPath: finalJSON.path) {
            throw MeetingRepositoryError.alreadyFinalized
        }

        // The checkpoint is the authoritative recovery record until both final
        // files exist. Refresh it first so an interrupted finalize never falls
        // back to an older roster generation.
        try writeJSON(roster, to: inProgressJSON)
        try writeJSON(roster, to: finalJSON)
        try writeCSV(roster, to: session.directoryURL.appendingPathComponent(Self.csvName))

        if fileManager.fileExists(atPath: inProgressJSON.path) {
            try fileManager.removeItem(at: inProgressJSON)
        }
    }

    /// Removes a session that became stale before the coordinator adopted it.
    public func discard(_ session: MeetingSession) throws {
        guard session.directoryURL.standardizedFileURL.deletingLastPathComponent()
                == rootDirectory.standardizedFileURL,
              fileManager.fileExists(atPath: session.directoryURL.path) else {
            throw MeetingRepositoryError.invalidSession
        }
        try fileManager.removeItem(at: session.directoryURL)
    }

    /// Returns finalized and recoverable exports, newest meeting first.
    public func recentExports(limit: Int = 20) throws -> [MeetingExport] {
        try recentExportListing(limit: limit).exports
    }

    /// Lists every readable export while isolating corruption or repair errors
    /// to the affected meeting directory.
    public func recentExportListing(limit: Int = 20) throws -> MeetingExportListing {
        guard limit >= 0 else {
            throw MeetingRepositoryError.invalidLimit
        }
        guard limit > 0, fileManager.fileExists(atPath: rootDirectory.path) else {
            return MeetingExportListing(exports: [], warnings: [])
        }

        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        var exports: [MeetingExport] = []
        var warnings: [String] = []
        for directory in directories {
            do {
                let values = try directory.resourceValues(forKeys: resourceKeys)
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let sessionID = Self.sessionID(fromFolderName: directory.lastPathComponent) else {
                    continue
                }

                let finalURL = directory.appendingPathComponent(Self.finalJSONName)
                let checkpointURL = directory.appendingPathComponent(Self.inProgressJSONName)
                let csvURL = directory.appendingPathComponent(Self.csvName)
                let hasFinal = fileManager.fileExists(atPath: finalURL.path)
                let hasCheckpoint = fileManager.fileExists(atPath: checkpointURL.path)

                let state: MeetingExport.State
                let roster: MeetingRoster
                if hasCheckpoint {
                    roster = try decodeRoster(at: checkpointURL)
                    let finalMatchesCheckpoint: Bool
                    if hasFinal, let finalRoster = try? decodeRoster(at: finalURL) {
                        finalMatchesCheckpoint = finalRoster == roster
                    } else {
                        finalMatchesCheckpoint = false
                    }

                    // Rebuild the derived CSV from authoritative JSON. Only
                    // promote an interrupted finalize when both JSON copies
                    // agree and CSV repair succeeds.
                    do {
                        try writeCSV(roster, to: csvURL)
                        if finalMatchesCheckpoint {
                            try fileManager.removeItem(at: checkpointURL)
                            state = .finalized
                        } else {
                            state = .inProgress
                        }
                    } catch {
                        state = .inProgress
                        warnings.append(
                            "Could not complete recovery for \(directory.lastPathComponent)."
                        )
                    }
                } else if hasFinal {
                    roster = try decodeRoster(at: finalURL)
                    state = .finalized
                    if !fileManager.fileExists(atPath: csvURL.path) {
                        do {
                            try writeCSV(roster, to: csvURL)
                        } catch {
                            warnings.append(
                                "Could not recreate the CSV for \(directory.lastPathComponent)."
                            )
                        }
                    }
                } else {
                    continue
                }

                let createdAt = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? roster.startedAt
                let session = MeetingSession(
                    id: sessionID,
                    meetingID: roster.id,
                    directoryURL: directory,
                    createdAt: createdAt
                )
                exports.append(MeetingExport(session: session, roster: roster, state: state))
            } catch {
                warnings.append("Could not read roster \(directory.lastPathComponent).")
            }
        }

        let sortedExports = Array(
            exports.sorted {
                if $0.roster.startedAt != $1.roster.startedAt {
                    return $0.roster.startedAt > $1.roster.startedAt
                }
                return $0.session.directoryURL.lastPathComponent
                    > $1.session.directoryURL.lastPathComponent
            }.prefix(limit)
        )
        return MeetingExportListing(exports: sortedExports, warnings: warnings)
    }

    private func writeCheckpoint(_ roster: MeetingRoster, in session: MeetingSession) throws {
        try writeJSON(
            roster,
            to: session.directoryURL.appendingPathComponent(Self.inProgressJSONName)
        )
        try writeCSV(
            roster,
            to: session.directoryURL.appendingPathComponent(Self.csvName)
        )
    }

    private func writeJSON(_ roster: MeetingRoster, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Dates.string(from: date))
        }
        try writePrivateFile(try encoder.encode(roster), to: url)
    }

    private func decodeRoster(at url: URL) throws -> MeetingRoster {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ISO8601Dates.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return date
        }
        return try decoder.decode(MeetingRoster.self, from: Data(contentsOf: url))
    }

    private func writeCSV(_ roster: MeetingRoster, to url: URL) throws {
        try writePrivateFile(MeetingCSV.data(for: roster), to: url)
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            // A user-selected root may intentionally have broader permissions.
            // Only directories created by RosterWren are forced private.
            return
        }

        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    private func validate(_ roster: MeetingRoster, session: MeetingSession) throws {
        guard session.meetingID == roster.id else {
            throw MeetingRepositoryError.meetingMismatch
        }
        guard session.directoryURL.standardizedFileURL.deletingLastPathComponent()
                == rootDirectory.standardizedFileURL else {
            throw MeetingRepositoryError.invalidSession
        }
        guard fileManager.fileExists(atPath: session.directoryURL.path) else {
            throw MeetingRepositoryError.invalidSession
        }
    }

    private static func folderName(startedAt: Date, sessionID: UUID) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return "\(formatter.string(from: startedAt))--\(sessionID.uuidString.lowercased())"
    }

    private static func sessionID(fromFolderName name: String) -> UUID? {
        guard let separator = name.range(of: "--", options: .backwards) else {
            return nil
        }
        return UUID(uuidString: String(name[separator.upperBound...]))
    }

    private static let inProgressJSONName = "meeting.json.inprogress"
    private static let finalJSONName = "meeting.json"
    private static let csvName = "participants.csv"
}

public struct MeetingSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let directoryURL: URL
    public let createdAt: Date

    fileprivate init(id: UUID, meetingID: UUID, directoryURL: URL, createdAt: Date) {
        self.id = id
        self.meetingID = meetingID
        self.directoryURL = directoryURL
        self.createdAt = createdAt
    }
}

public struct MeetingExport: Identifiable, Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case inProgress
        case finalized
    }

    public var id: UUID { session.id }
    public let session: MeetingSession
    public let roster: MeetingRoster
    public let state: State
}

public struct MeetingExportListing: Equatable, Sendable {
    public let exports: [MeetingExport]
    public let warnings: [String]
}

public enum MeetingRepositoryError: Error, Equatable, Sendable {
    case meetingMismatch
    case invalidSession
    case alreadyFinalized
    case invalidLimit
}
