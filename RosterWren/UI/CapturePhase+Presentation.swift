import SwiftUI

extension CapturePhase {
    var title: String {
        switch self {
        case .onboarding: "Ready to set up"
        case .permissionRequired: "Accessibility access needed"
        case .paused: "Roster capture is paused"
        case .waitingForZoom: "Waiting for Zoom"
        case .waitingForMeeting: "Waiting for a meeting"
        case .confirmingMeeting: "Meeting detected"
        case .startingCapture: "Preparing roster capture"
        case .capturing: "Capturing this roster"
        case .ending: "Checking whether the meeting ended"
        case .saving: "Saving roster"
        case .error: "RosterWren needs attention"
        }
    }

    var detail: String {
        switch self {
        case .onboarding:
            "Review what RosterWren reads and where it stores names."
        case .permissionRequired:
            "Enable RosterWren in Privacy & Security so it can read Zoom's participant list."
        case .paused:
            "No participant names are being read."
        case .waitingForZoom:
            "Open Zoom Workplace; capture will begin after a meeting starts."
        case .waitingForMeeting:
            "Zoom is open. Join or start a meeting when you are ready."
        case .confirmingMeeting:
            "RosterWren is confirming the meeting before it creates a file."
        case .startingCapture:
            "Creating the private meeting folder and its first recovery checkpoint."
        case .capturing:
            "Names are checkpointed locally while the meeting is running."
        case let .ending(secondsRemaining):
            "The meeting window disappeared. Saving in \(secondsRemaining) seconds unless it returns."
        case .saving:
            "Writing the final private JSON and CSV files."
        case let .error(message):
            message
        }
    }

    var symbol: String {
        switch self {
        case .onboarding: "hand.raised"
        case .permissionRequired: "lock.trianglebadge.exclamationmark"
        case .paused: "pause.circle"
        case .waitingForZoom: "video.slash"
        case .waitingForMeeting: "video"
        case .confirmingMeeting: "ellipsis.circle"
        case .startingCapture: "folder.badge.plus"
        case .capturing: "person.2.fill"
        case .ending: "clock"
        case .saving: "square.and.arrow.down"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .capturing: "person.2.fill"
        case .paused: "pause.circle"
        case .permissionRequired, .error: "exclamationmark.triangle"
        default: "person.2"
        }
    }

    var tint: Color {
        switch self {
        case .capturing: .red
        case .permissionRequired, .error: .orange
        case .paused: .secondary
        case .saving, .confirmingMeeting, .startingCapture, .ending: .blue
        default: .accentColor
        }
    }
}
