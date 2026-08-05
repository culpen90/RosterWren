import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if !model.hasConsented {
                    onboarding
                } else {
                    statusCard
                    captureControls
                    currentRoster
                    recentRosters
                    storageAndPrivacy
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private extension ContentView {
    var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text("RosterWren")
                    .font(.title.bold())
                Text("A local roster companion for Zoom Workplace")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    var onboarding: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("Roster data is stored in an app-owned folder", systemImage: "lock.shield")
                    .font(.title3.weight(.semibold))

                Text("RosterWren traverses structural Accessibility attributes inside the Zoom process to locate meeting and participant controls. It reads text values only inside rows Zoom identifies as panelists. It does not record audio, video, chat, or screenshots, and it makes no network requests.")
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 9) {
                    consentRow("Inspects structural data only in Zoom; reads text values only from identified panelist rows", icon: "person.text.rectangle")
                    consentRow("Saves owner-only JSON and CSV files in an app-owned roster folder", icon: "folder.badge.gearshape")
                    consentRow("May open Zoom's Participants panel automatically once, or when you request it", icon: "rectangle.rightthird.inset.filled")
                }
                .foregroundStyle(.secondary)

                Toggle(
                    "Allow RosterWren to open Zoom's Participants panel once per meeting",
                    isOn: $model.autoRevealParticipants
                )

                Text("Participant names are personal data. Use RosterWren only where you are authorized to retain them. macOS grants broad Accessibility permission even though this app deliberately inspects only Zoom.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Enable Roster Capture") {
                        model.acceptPrivacyNoticeAndRequestAccess()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Choose Parent Folder…") {
                        model.chooseSaveFolder()
                    }

                    Spacer()
                }
            }
            .padding(8)
        }
    }

    func consentRow(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .fixedSize(horizontal: false, vertical: true)
    }

    var statusCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: model.phase.symbol)
                    .font(.title2)
                    .foregroundStyle(model.phase.tint)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.phase.title)
                        .font(.headline)
                    Text(model.phase.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if case .capturing = model.phase {
                    Text("\(model.currentNames.count) observed")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            .padding(6)

            if !model.allWarnings.isEmpty {
                Divider().padding(.vertical, 5)
                ForEach(model.allWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    var captureControls: some View {
        GroupBox("Capture") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if model.captureEnabled {
                        Button("Pause & Save") { model.pauseAndSave() }
                            .buttonStyle(.borderedProminent)
                            .tint(.secondary)
                    } else {
                        Button("Resume Automatic Capture") { model.resume() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canResume)
                    }

                    Button("Open Participants Now") { model.openParticipantsNow() }
                        .disabled(!model.canOpenParticipants)

                    Spacer()

                    if !model.isAccessibilityTrusted {
                        Button("Grant Accessibility Access") {
                            model.requestAccessibilityAccess()
                        }
                        Button("Open System Settings") {
                            model.openAccessibilitySettings()
                        }
                    }
                }

                if !model.isAccessibilityTrusted {
                    Divider()

                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            "macOS must authorize this signed copy of RosterWren:",
                            systemImage: "app.badge.checkmark"
                        )
                        .font(.callout.weight(.medium))

                        Text(Bundle.main.bundleURL.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)

                        Text("If an older RosterWren entry is already enabled, remove it and add the copy shown above. Quit from the menu-bar menu before reopening; closing this window keeps RosterWren running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(
                    "Open Zoom's Participants panel once when a meeting begins",
                    isOn: $model.autoRevealParticipants
                )
                .disabled(model.hasActiveMeeting)
            }
            .padding(.vertical, 4)
        }
    }

    var currentRoster: some View {
        GroupBox("Current meeting") {
            if model.currentNames.isEmpty {
                ContentUnavailableView(
                    "No names observed yet",
                    systemImage: "person.2",
                    description: Text("Names appear after Zoom exposes its Participants list.")
                )
                .frame(minHeight: 110)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(Array(model.currentNames.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "person.crop.circle")
                            .lineLimit(1)
                            .help(name)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    var recentRosters: some View {
        GroupBox("Recent rosters") {
            if model.recentExports.isEmpty {
                Text("Completed and recoverable rosters will appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recentExports) { export in
                        HStack {
                            Image(systemName: export.state == .finalized ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                                .foregroundStyle(export.state == .finalized ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(export.roster.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout.weight(.medium))
                                Text("\(export.roster.participants.count) observed · \(export.state == .finalized ? "Saved" : "Recoverable checkpoint")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reveal") { model.revealExport(export) }
                        }
                        .padding(.vertical, 7)

                        if export.id != model.recentExports.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    var storageAndPrivacy: some View {
        GroupBox("Storage & privacy") {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Image(systemName: "folder")
                    Text(model.saveFolderURL.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Open Folder") { model.openSaveFolder() }
                    Button("Change Parent…") { model.chooseSaveFolder() }
                        .disabled(!model.canChangeFolder)
                }

                Text("When you choose a location, RosterWren creates and protects a dedicated RosterWren Meetings child folder there; it does not change the parent folder's permissions. No telemetry or network service is used. A child folder inside iCloud Drive or another synced location may leave this Mac through that service. The Accessibility fallback is a locally observed roster, not an authoritative Zoom attendance report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }
}
