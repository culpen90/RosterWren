import Foundation

/// One display-name occurrence observed in a meeting.
///
/// A record is matched only to later observations with the same normalized,
/// case-insensitive display name. RosterWren deliberately does not guess that a
/// differently named participant is the same person.
public struct ParticipantRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public private(set) var displayName: String
    public let firstSeen: Date
    public private(set) var lastSeen: Date
    public private(set) var observationCount: Int
    public private(set) var isPresent: Bool

    fileprivate init(id: UUID = UUID(), displayName: String, observedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.firstSeen = observedAt
        self.lastSeen = observedAt
        self.observationCount = 1
        self.isPresent = true
    }

    fileprivate mutating func recordObservation(displayName: String, at date: Date) {
        // Keep the exact spelling most recently supplied by Zoom. Normalization
        // is used solely for matching and is never persisted in its place.
        self.displayName = displayName
        self.lastSeen = max(lastSeen, date)
        self.observationCount += 1
        self.isPresent = true
    }

    fileprivate mutating func markAbsent() {
        isPresent = false
    }
}

public struct MeetingRoster: Codable, Identifiable, Equatable, Sendable {
    public enum CaptureSource: String, Codable, Equatable, Sendable {
        case zoomAccessibility
        case zoomPluginSDK
    }

    public enum EndReason: String, Codable, Equatable, Sendable {
        case meetingEnded
        case zoomQuit
        case replacedByAnotherMeeting
        case pausedByUser
        case appQuit
    }

    public let id: UUID
    public var title: String?
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var endReason: EndReason?
    public private(set) var lastObservedAt: Date?
    public private(set) var observationCount: Int
    public private(set) var participants: [ParticipantRecord]
    public let captureSource: CaptureSource
    public private(set) var zoomVersion: String?
    public private(set) var participantPanelObserved: Bool
    public private(set) var scanWasTruncated: Bool
    public private(set) var captureWarnings: [String]

    public var presentParticipants: [ParticipantRecord] {
        participants.filter(\.isPresent)
    }

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        startedAt: Date = Date(),
        captureSource: CaptureSource = .zoomAccessibility,
        zoomVersion: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = nil
        self.endReason = nil
        self.lastObservedAt = nil
        self.observationCount = 0
        self.participants = []
        self.captureSource = captureSource
        self.zoomVersion = zoomVersion
        self.participantPanelObserved = false
        self.scanWasTruncated = false
        self.captureWarnings = []
    }

    /// Reconciles a complete Zoom participant-list snapshot into the roster.
    ///
    /// Equal names are handled as a multiset: two simultaneous "Alex" rows
    /// produce two records and can never collapse into one. Participants absent
    /// from a later snapshot remain in `participants`, with `isPresent == false`.
    public mutating func observe(displayNames: [String], at date: Date = Date()) {
        let previouslyPresentIDs = Set(
            participants.lazy.filter(\.isPresent).map(\.id)
        )

        for index in participants.indices {
            participants[index].markAbsent()
        }

        var candidatesByName: [String: [Int]] = [:]
        for index in participants.indices {
            let key = ParticipantNameNormalization.matchKey(participants[index].displayName)
            candidatesByName[key, default: []].append(index)
        }

        var matchedIndices = Set<Int>()

        for rawDisplayName in displayNames {
            let key = ParticipantNameNormalization.matchKey(rawDisplayName)
            let candidates = candidatesByName[key, default: []]

            // Exact raw spelling is only a tie-breaker between equal normalized
            // names. Previously present occurrences are preferred so duplicate
            // identities remain stable as the visible multiplicity shrinks.
            let matchingIndex = candidates.first {
                !matchedIndices.contains($0)
                    && previouslyPresentIDs.contains(participants[$0].id)
                    && participants[$0].displayName == rawDisplayName
            } ?? candidates.first {
                !matchedIndices.contains($0)
                    && previouslyPresentIDs.contains(participants[$0].id)
            } ?? candidates.first {
                !matchedIndices.contains($0)
                    && participants[$0].displayName == rawDisplayName
            } ?? candidates.first {
                !matchedIndices.contains($0)
            }

            if let matchingIndex {
                participants[matchingIndex].recordObservation(
                    displayName: rawDisplayName,
                    at: date
                )
                matchedIndices.insert(matchingIndex)
            } else {
                participants.append(
                    ParticipantRecord(displayName: rawDisplayName, observedAt: date)
                )
                matchedIndices.insert(participants.index(before: participants.endIndex))
            }
        }

        lastObservedAt = max(lastObservedAt ?? date, date)
        observationCount += 1
    }

    public mutating func recordCaptureStatus(
        zoomVersion: String?,
        participantPanelObserved: Bool,
        scanWasTruncated: Bool,
        warnings: [String]
    ) {
        if let zoomVersion, !zoomVersion.isEmpty {
            self.zoomVersion = zoomVersion
        }
        self.participantPanelObserved = self.participantPanelObserved
            || participantPanelObserved
        self.scanWasTruncated = self.scanWasTruncated || scanWasTruncated
        for warning in warnings where !captureWarnings.contains(warning) {
            captureWarnings.append(warning)
        }
    }

    public mutating func finish(
        at date: Date = Date(),
        reason: EndReason = .meetingEnded
    ) {
        endedAt = max(date, lastObservedAt ?? startedAt)
        endReason = reason
    }
}

/// The intentionally narrow display-name normalization used for identity
/// matching. It does not remove punctuation, accents, or other distinctions.
public enum ParticipantNameNormalization: Sendable {
    /// Applies NFC and trims/collapses Unicode whitespace to ASCII spaces.
    public static func normalized(_ displayName: String) -> String {
        let nfcName = displayName.precomposedStringWithCanonicalMapping
        var result = ""
        var needsSeparator = false

        for character in nfcName {
            if character.isWhitespace {
                if !result.isEmpty {
                    needsSeparator = true
                }
                continue
            }

            if needsSeparator {
                result.append(" ")
                needsSeparator = false
            }
            result.append(character)
        }

        return result
    }

    fileprivate static func matchKey(_ displayName: String) -> String {
        normalized(displayName)
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }
}
