import AppKit
import SwiftUI

struct RosterWrenMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.phase.title)
        if model.hasActiveMeeting {
            Text("\(model.currentNames.count) participants observed")
        }

        Divider()

        Button("Open RosterWren") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Button("Open Participants Now") {
            model.openParticipantsNow()
        }
        .disabled(!model.canOpenParticipants)

        if model.captureEnabled {
            Button("Pause & Save") { model.pauseAndSave() }
        } else {
            Button("Resume Automatic Capture") { model.resume() }
                .disabled(!model.canResume)
        }

        Button("Open Roster Folder") { model.openSaveFolder() }

        Divider()

        Button("Quit RosterWren") { model.quitAfterSaving() }
    }
}
