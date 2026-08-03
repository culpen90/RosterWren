import AppKit
import SwiftUI

@MainActor
private final class RosterWrenApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard model.requiresTerminationPreparation else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }

            let shouldTerminate = await model.prepareForTermination()
            terminationTask = nil
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}

@main
struct RosterWrenApp: App {
    @NSApplicationDelegateAdaptor(RosterWrenApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        Window("RosterWren", id: "main") {
            ContentView(model: applicationDelegate.model)
                .frame(minWidth: 720, minHeight: 600)
        }
        .defaultSize(width: 780, height: 680)

        MenuBarExtra {
            RosterWrenMenu(model: applicationDelegate.model)
        } label: {
            RosterWrenMenuBarLabel(model: applicationDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct RosterWrenMenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Label("RosterWren", systemImage: model.phase.menuBarSymbol)
    }
}
