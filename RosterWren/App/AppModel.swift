import AppKit
import Foundation

@MainActor
protocol ZoomCaptureSource: AnyObject {
    func requestAccessibilityAccess(prompt: Bool) -> Bool
    func captureParticipants(allowReveal: Bool) async -> ZoomCaptureSnapshot
}

extension ZoomAccessibilityClient: ZoomCaptureSource {}

enum CapturePhase: Equatable {
    case onboarding
    case permissionRequired
    case paused
    case waitingForZoom
    case waitingForMeeting
    case confirmingMeeting
    case startingCapture
    case capturing
    case ending(secondsRemaining: Int)
    case saving
    case error(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let consentVersion = 1

    @Published private(set) var phase: CapturePhase
    @Published private(set) var hasConsented: Bool
    @Published private(set) var captureEnabled: Bool
    @Published private(set) var isAccessibilityTrusted: Bool
    @Published private(set) var currentNames: [String] = []
    @Published private(set) var recentExports: [MeetingExport] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var storageWarnings: [String] = []
    @Published private(set) var saveFolderURL: URL
    @Published private(set) var isPausing = false
    @Published var autoRevealParticipants: Bool {
        didSet {
            defaults.set(autoRevealParticipants, forKey: PreferenceKey.autoRevealParticipants)
        }
    }

    var hasActiveMeeting: Bool { activeCapture != nil }
    var allWarnings: [String] {
        Array(Set(warnings + storageWarnings)).sorted()
    }
    var canChangeFolder: Bool {
        activeCapture == nil
            && !isStartingCapture
            && !isFinalizing
            && !isPausing
    }
    var canResume: Bool {
        !captureEnabled
            && !isPausing
            && !isStartingCapture
            && !isFinalizing
    }
    var canOpenParticipants: Bool {
        captureEnabled
            && isAccessibilityTrusted
            && activeCapture != nil
            && activeZoomOperationID == nil
            && !isFinalizing
    }

    private struct ActiveCapture {
        var roster: MeetingRoster
        let session: MeetingSession
        let repository: MeetingRepository
        var meetingToken: String?
        var lastMeetingSeenAt: Date
        var endDeadline: Date?
        var revealPending: Bool
        var nextRevealAttemptAt: Date
        var lastCheckpointAt: Date
    }

    private enum PreferenceKey {
        static let consentVersion = "privacyConsentVersion"
        static let captureEnabled = "captureEnabled"
        static let autoRevealParticipants = "autoRevealParticipants"
        static let saveFolderPath = "saveFolderPath"
    }

    private let defaults: UserDefaults
    private let zoom: any ZoomCaptureSource
    private let nowProvider: () -> Date
    private var repository: MeetingRepository
    private var activeCapture: ActiveCapture?
    private var meetingConfirmations = 0
    private var candidateMeetingToken: String?
    private var pollingTask: Task<Void, Never>?
    private var manualRevealTask: Task<Void, Never>?
    private var pauseTransitionTask: Task<Void, Never>?
    private var activeZoomOperationID: UUID?
    private var isFinalizing = false
    private var isStartingCapture = false
    private var operationGeneration: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        zoom: any ZoomCaptureSource = ZoomAccessibilityClient(),
        startsPolling: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        let storedConsent = defaults.integer(forKey: PreferenceKey.consentVersion)
        let resolvedConsent = storedConsent >= Self.consentVersion

        let resolvedCaptureEnabled: Bool
        if defaults.object(forKey: PreferenceKey.captureEnabled) == nil {
            resolvedCaptureEnabled = true
        } else {
            resolvedCaptureEnabled = defaults.bool(forKey: PreferenceKey.captureEnabled)
        }

        let resolvedAutoReveal: Bool
        if defaults.object(forKey: PreferenceKey.autoRevealParticipants) == nil {
            resolvedAutoReveal = true
        } else {
            resolvedAutoReveal = defaults.bool(
                forKey: PreferenceKey.autoRevealParticipants
            )
        }

        let resolvedFolder: URL
        if let storedPath = defaults.string(forKey: PreferenceKey.saveFolderPath),
           !storedPath.isEmpty {
            resolvedFolder = URL(fileURLWithPath: storedPath, isDirectory: true)
                .standardizedFileURL
        } else {
            resolvedFolder = MeetingRepository.defaultRootDirectory
        }
        let trusted = zoom.requestAccessibilityAccess(prompt: false)
        let initialPhase: CapturePhase
        if !resolvedConsent {
            initialPhase = .onboarding
        } else if !resolvedCaptureEnabled {
            initialPhase = .paused
        } else if !trusted {
            initialPhase = .permissionRequired
        } else {
            initialPhase = .waitingForZoom
        }

        self.defaults = defaults
        self.zoom = zoom
        self.nowProvider = now
        self.hasConsented = resolvedConsent
        self.captureEnabled = resolvedCaptureEnabled
        self.autoRevealParticipants = resolvedAutoReveal
        self.saveFolderURL = resolvedFolder
        self.repository = MeetingRepository(rootDirectory: resolvedFolder)
        self.isAccessibilityTrusted = trusted
        self.phase = initialPhase

        ensureSaveFolderExists()
        if startsPolling {
            start()
        }
        Task { [weak self] in
            await self?.refreshRecentExports()
        }
    }

    func start() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()

                do {
                    try await Task.sleep(for: .seconds(self.pollInterval))
                } catch {
                    return
                }
            }
        }
    }

    /// Executes a single reducer pass. Kept internal so deterministic fixture
    /// tests can verify meeting confirmation and reveal throttling.
    func runOnePoll() async {
        await pollOnce()
    }

    func acceptPrivacyNoticeAndRequestAccess() {
        operationGeneration &+= 1
        defaults.set(Self.consentVersion, forKey: PreferenceKey.consentVersion)
        defaults.set(true, forKey: PreferenceKey.captureEnabled)
        hasConsented = true
        captureEnabled = true
        isAccessibilityTrusted = zoom.requestAccessibilityAccess(prompt: true)
        phase = isAccessibilityTrusted ? .waitingForZoom : .permissionRequired
        start()
    }

    func requestAccessibilityAccess() {
        isAccessibilityTrusted = zoom.requestAccessibilityAccess(prompt: true)
        if isAccessibilityTrusted, hasConsented, captureEnabled {
            phase = .waitingForZoom
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func pauseAndSave() {
        guard captureEnabled, pauseTransitionTask == nil else { return }
        isPausing = true
        operationGeneration &+= 1
        captureEnabled = false
        defaults.set(false, forKey: PreferenceKey.captureEnabled)
        meetingConfirmations = 0
        candidateMeetingToken = nil

        let priorPollingTask = pollingTask
        pollingTask = nil
        priorPollingTask?.cancel()
        let priorManualRevealTask = manualRevealTask
        manualRevealTask = nil
        priorManualRevealTask?.cancel()

        phase = activeCapture == nil && !isStartingCapture && activeZoomOperationID == nil
            ? .paused
            : .saving
        pauseTransitionTask = Task { [weak self] in
            guard let self else { return }
            await priorPollingTask?.value
            await priorManualRevealTask?.value
            _ = await self.finalizeActiveCapture(
                at: self.nowProvider(),
                reason: .pausedByUser,
                nextPhase: .paused
            )
            self.pauseTransitionTask = nil
            self.isPausing = false
        }
    }

    func resume() {
        guard canResume else { return }
        operationGeneration &+= 1
        captureEnabled = true
        defaults.set(true, forKey: PreferenceKey.captureEnabled)
        meetingConfirmations = 0
        warnings = []
        phase = isAccessibilityTrusted ? .waitingForZoom : .permissionRequired
        start()
    }

    func openParticipantsNow() {
        guard canOpenParticipants else { return }
        let generation = operationGeneration
        let operationID = UUID()
        activeZoomOperationID = operationID
        manualRevealTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.zoom.captureParticipants(allowReveal: true)
            if self.activeZoomOperationID == operationID {
                self.activeZoomOperationID = nil
            }
            self.manualRevealTask = nil
            guard generation == self.operationGeneration,
                  self.captureEnabled,
                  self.activeCapture != nil else { return }
            self.warnings = snapshot.warnings
        }
    }

    func chooseSaveFolder() {
        guard canChangeFolder else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose where RosterWren saves meeting rosters"
        panel.prompt = "Choose Save Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        operationGeneration &+= 1
        meetingConfirmations = 0
        candidateMeetingToken = nil
        let selectedParent = selectedURL.standardizedFileURL
        if selectedParent.lastPathComponent == "RosterWren Meetings" {
            saveFolderURL = selectedParent
        } else {
            saveFolderURL = selectedParent.appendingPathComponent(
                "RosterWren Meetings",
                isDirectory: true
            )
        }
        defaults.set(saveFolderURL.path, forKey: PreferenceKey.saveFolderPath)
        repository = MeetingRepository(rootDirectory: saveFolderURL)
        ensureSaveFolderExists()
        Task { [weak self] in
            await self?.refreshRecentExports()
        }
    }

    func openSaveFolder() {
        ensureSaveFolderExists()
        NSWorkspace.shared.open(saveFolderURL)
    }

    func revealExport(_ export: MeetingExport) {
        let csvURL = export.session.directoryURL.appendingPathComponent("participants.csv")
        if FileManager.default.fileExists(atPath: csvURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([csvURL])
        } else {
            NSWorkspace.shared.open(export.session.directoryURL)
        }
    }

    func quitAfterSaving() {
        NSApplication.shared.terminate(nil)
    }

    var requiresTerminationPreparation: Bool {
        activeCapture != nil
            || isStartingCapture
            || isFinalizing
            || activeZoomOperationID != nil
            || pauseTransitionTask != nil
    }

    func prepareForTermination() async -> Bool {
        operationGeneration &+= 1
        let priorPollingTask = pollingTask
        pollingTask = nil
        priorPollingTask?.cancel()
        let priorManualRevealTask = manualRevealTask
        manualRevealTask = nil
        priorManualRevealTask?.cancel()
        let priorPauseTransitionTask = pauseTransitionTask
        await priorPollingTask?.value
        await priorManualRevealTask?.value
        await priorPauseTransitionTask?.value
        let saved = await finalizeActiveCapture(
            at: nowProvider(),
            reason: .appQuit,
            nextPhase: captureEnabled ? .waitingForMeeting : .paused
        )
        if !saved, captureEnabled, hasConsented {
            start()
        }
        return saved
    }
}

private extension AppModel {
    var pollInterval: Double {
        switch phase {
        case .onboarding, .permissionRequired:
            return 1
        case .waitingForZoom, .paused:
            return 4
        case .waitingForMeeting:
            return 3
        case .confirmingMeeting, .startingCapture, .capturing, .ending, .saving, .error:
            return 1.5
        }
    }

    func pollOnce() async {
        let trusted = zoom.requestAccessibilityAccess(prompt: false)
        isAccessibilityTrusted = trusted

        guard hasConsented else {
            phase = .onboarding
            return
        }
        guard captureEnabled else {
            if activeCapture == nil, !isFinalizing {
                phase = .paused
            }
            return
        }
        guard trusted else {
            phase = .permissionRequired
            return
        }
        guard !isFinalizing, !isStartingCapture, activeZoomOperationID == nil else {
            return
        }

        let now = nowProvider()
        let allowReveal = activeCapture.map {
            $0.revealPending && now >= $0.nextRevealAttemptAt
        } ?? false
        let generation = operationGeneration
        let operationID = UUID()
        let repositoryAtStart = repository
        activeZoomOperationID = operationID
        let snapshot = await zoom.captureParticipants(allowReveal: allowReveal)
        if activeZoomOperationID == operationID {
            activeZoomOperationID = nil
        }

        // Every async capture can re-enter the main actor. Pause, folder changes,
        // and termination all advance this generation so stale results cannot
        // mutate state or start a new session after control has changed.
        guard generation == operationGeneration,
              captureEnabled,
              hasConsented,
              isAccessibilityTrusted,
              !isFinalizing else {
            return
        }

        warnings = snapshot.warnings

        if var capture = activeCapture {
            if snapshot.panelDetected || (allowReveal && snapshot.revealAttempted) {
                capture.revealPending = false
            } else if allowReveal {
                // A control can be temporarily absent while Zoom rearranges its
                // toolbar. Retry later only when no action reached Zoom.
                capture.nextRevealAttemptAt = now.addingTimeInterval(5)
            }
            activeCapture = capture
        }

        // Only complete, trustworthy scans are evidence of either a running
        // meeting or its absence. Any AX failure breaks the continuous end grace.
        guard snapshot.isReliable, !snapshot.scanTruncated else {
            meetingConfirmations = 0
            candidateMeetingToken = nil
            if var capture = activeCapture {
                capture.endDeadline = nil
                activeCapture = capture
            }
            phase = .error(
                snapshot.warnings.isEmpty
                    ? "Zoom's accessibility scan was incomplete."
                    : snapshot.warnings.joined(separator: " ")
            )
            return
        }

        if !snapshot.zoomRunning {
            meetingConfirmations = 0
            candidateMeetingToken = nil
            if activeCapture != nil {
                _ = await finalizeActiveCapture(
                    at: now,
                    reason: .zoomQuit,
                    nextPhase: .waitingForZoom
                )
            } else {
                phase = .waitingForZoom
            }
            return
        }

        if snapshot.meetingDetected {
            if activeCapture == nil {
                if meetingConfirmations > 0,
                   candidateMeetingToken == snapshot.meetingToken {
                    meetingConfirmations += 1
                } else {
                    candidateMeetingToken = snapshot.meetingToken
                    meetingConfirmations = 1
                }
                guard meetingConfirmations >= 2 else {
                    phase = .confirmingMeeting
                    return
                }
                await beginCapture(
                    from: snapshot,
                    at: now,
                    generation: generation,
                    repositoryAtStart: repositoryAtStart
                )
            } else {
                if activeCapture?.meetingToken == nil,
                   let incomingToken = snapshot.meetingToken {
                    activeCapture?.meetingToken = incomingToken
                }
                if let activeToken = activeCapture?.meetingToken,
                   let incomingToken = snapshot.meetingToken,
                   activeToken != incomingToken {
                    let endedAt = activeCapture?.lastMeetingSeenAt ?? now
                    let saved = await finalizeActiveCapture(
                        at: endedAt,
                        reason: .replacedByAnotherMeeting,
                        nextPhase: .confirmingMeeting
                    )
                    if saved {
                        candidateMeetingToken = incomingToken
                        meetingConfirmations = 1
                        phase = .confirmingMeeting
                    }
                    return
                }
                await updateActiveCapture(from: snapshot, at: now)
            }
            return
        }

        meetingConfirmations = 0
        candidateMeetingToken = nil
        guard var capture = activeCapture else {
            phase = .waitingForMeeting
            return
        }

        if capture.endDeadline == nil {
            capture.endDeadline = now.addingTimeInterval(15)
            activeCapture = capture
        }

        guard let deadline = capture.endDeadline else { return }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        if remaining == 0 {
            _ = await finalizeActiveCapture(
                at: capture.lastMeetingSeenAt,
                reason: .meetingEnded,
                nextPhase: .waitingForMeeting
            )
        } else {
            phase = .ending(secondsRemaining: remaining)
        }
    }

    func beginCapture(
        from snapshot: ZoomCaptureSnapshot,
        at date: Date,
        generation: UInt64,
        repositoryAtStart: MeetingRepository
    ) async {
        guard generation == operationGeneration,
              captureEnabled,
              activeCapture == nil,
              !isFinalizing else {
            return
        }
        isStartingCapture = true
        phase = .startingCapture

        var roster = MeetingRoster(
            title: "Zoom Meeting",
            startedAt: date,
            captureSource: .zoomAccessibility,
            zoomVersion: snapshot.version
        )
        roster.recordCaptureStatus(
            zoomVersion: snapshot.version,
            participantPanelObserved: snapshot.panelDetected,
            scanWasTruncated: snapshot.scanTruncated,
            warnings: snapshot.warnings
        )
        if snapshot.panelDetected, snapshot.isReliable, !snapshot.scanTruncated {
            roster.observe(displayNames: snapshot.names, at: date)
        }

        do {
            let session = try await repositoryAtStart.createMeeting(for: roster)
            guard generation == operationGeneration,
                  captureEnabled,
                  hasConsented,
                  isAccessibilityTrusted,
                  activeCapture == nil,
                  repositoryAtStart.rootDirectory == repository.rootDirectory else {
                try? await repositoryAtStart.discard(session)
                isStartingCapture = false
                return
            }
            activeCapture = ActiveCapture(
                roster: roster,
                session: session,
                repository: repositoryAtStart,
                meetingToken: snapshot.meetingToken,
                lastMeetingSeenAt: date,
                endDeadline: nil,
                revealPending: autoRevealParticipants && !snapshot.panelDetected,
                nextRevealAttemptAt: date,
                lastCheckpointAt: date
            )
            meetingConfirmations = 0
            candidateMeetingToken = nil
            isStartingCapture = false
            currentNames = roster.presentParticipants.map(\.displayName)
            phase = .capturing
            await refreshRecentExports()
        } catch {
            meetingConfirmations = 0
            candidateMeetingToken = nil
            isStartingCapture = false
            if generation == operationGeneration, captureEnabled {
                phase = .error("Roster folder is not writable: \(error.localizedDescription)")
            }
        }
    }

    func updateActiveCapture(from snapshot: ZoomCaptureSnapshot, at date: Date) async {
        guard var capture = activeCapture else { return }
        capture.lastMeetingSeenAt = date
        capture.endDeadline = nil
        capture.roster.recordCaptureStatus(
            zoomVersion: snapshot.version,
            participantPanelObserved: snapshot.panelDetected,
            scanWasTruncated: snapshot.scanTruncated,
            warnings: snapshot.warnings
        )

        var membershipChanged = false
        if snapshot.panelDetected, snapshot.isReliable, !snapshot.scanTruncated {
            let before = capture.roster.presentParticipants
                .map(\.displayName)
                .sorted()
            capture.roster.observe(displayNames: snapshot.names, at: date)
            let after = capture.roster.presentParticipants
                .map(\.displayName)
                .sorted()
            membershipChanged = before != after
        }

        currentNames = capture.roster.presentParticipants.map(\.displayName)
        activeCapture = capture
        phase = .capturing

        if membershipChanged || date.timeIntervalSince(capture.lastCheckpointAt) >= 5 {
            await checkpointActiveCapture(at: date)
        }
    }

    func checkpointActiveCapture(at date: Date) async {
        guard var capture = activeCapture else { return }
        do {
            try await capture.repository.checkpoint(capture.roster, in: capture.session)
            capture.lastCheckpointAt = date
            if activeCapture?.session.id == capture.session.id {
                activeCapture = capture
            }
        } catch {
            phase = .error("The live roster could not be saved: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func finalizeActiveCapture(
        at date: Date,
        reason: MeetingRoster.EndReason,
        nextPhase: CapturePhase
    ) async -> Bool {
        guard !isFinalizing else { return false }
        guard var capture = activeCapture else {
            phase = nextPhase
            return true
        }

        isFinalizing = true
        phase = .saving
        capture.roster.finish(at: date, reason: reason)

        do {
            try await capture.repository.finalize(capture.roster, in: capture.session)
            if activeCapture?.session.id == capture.session.id {
                activeCapture = nil
                currentNames = []
            }
            isFinalizing = false
            phase = nextPhase
            warnings = []
            await refreshRecentExports()
            return true
        } catch {
            isFinalizing = false
            phase = .error("The roster could not be finalized: \(error.localizedDescription)")
            return false
        }
    }

    func refreshRecentExports() async {
        let generation = operationGeneration
        let repositoryAtStart = repository
        do {
            let listing = try await repositoryAtStart.recentExportListing(limit: 12)
            guard generation == operationGeneration,
                  repositoryAtStart.rootDirectory == repository.rootDirectory else {
                return
            }
            recentExports = listing.exports
            storageWarnings = listing.warnings
        } catch {
            guard generation == operationGeneration else { return }
            if case .error = phase {
                return
            }
            phase = .error("Saved rosters could not be listed: \(error.localizedDescription)")
        }
    }

    func ensureSaveFolderExists() {
        do {
            let alreadyExists = FileManager.default.fileExists(atPath: saveFolderURL.path)
            try FileManager.default.createDirectory(
                at: saveFolderURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            if !alreadyExists {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: saveFolderURL.path
                )
            }
        } catch {
            phase = .error("Roster folder is not writable: \(error.localizedDescription)")
        }
    }
}
