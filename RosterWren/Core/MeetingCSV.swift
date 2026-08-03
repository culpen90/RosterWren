import Foundation

enum MeetingCSV {
    static func data(for roster: MeetingRoster) -> Data {
        var rows = [
            [
                "participant_id",
                "display_name",
                "first_seen",
                "last_seen",
                "observation_count",
                "is_present"
            ]
        ]

        rows.append(contentsOf: roster.participants.map { participant in
            [
                participant.id.uuidString.lowercased(),
                neutralizeFormula(in: participant.displayName),
                ISO8601Dates.string(from: participant.firstSeen),
                ISO8601Dates.string(from: participant.lastSeen),
                String(participant.observationCount),
                String(participant.isPresent)
            ]
        })

        // RFC 4180 records use CRLF, including the final record terminator.
        let csv = rows
            .map { $0.map(escape).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
        return Data(csv.utf8)
    }

    private static func neutralizeFormula(in value: String) -> String {
        let firstMeaningfulScalar = value.unicodeScalars.first {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
        }
        guard let firstMeaningfulScalar,
              "=+-@".unicodeScalars.contains(firstMeaningfulScalar) else {
            return value
        }
        return "'" + value
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum ISO8601Dates {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }
}
