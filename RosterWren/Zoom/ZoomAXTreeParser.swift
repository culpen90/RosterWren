import Foundation

public enum ZoomRevealDecision: Equatable, Sendable {
    case none
    case pressParticipantButton
    case pressShowParticipantsMenuItem
}

/// Pure parsing and reveal-policy logic for a value-only Zoom accessibility tree.
public struct ZoomAXTreeParser: Sendable {
    public struct Limits: Equatable, Sendable {
        public let maximumNodes: Int
        public let maximumDepth: Int

        public init(maximumNodes: Int = 2_000, maximumDepth: Int = 40) {
            self.maximumNodes = max(1, maximumNodes)
            self.maximumDepth = max(0, maximumDepth)
        }
    }

    public static let zoomBundleIdentifier = "us.zoom.xos"
    public static let meetingWindowIdentifier = "zm.meeting.window.main"
    public static let participantButtonIdentifier = "participant"
    public static let showParticipantsMenuIdentifier = "onManageParticipants:"
    public static let showParticipantsMenuTitle = "Show participants"
    public static let participantsListDescription = "Participants list"
    public static let panelistCellIdentifier = "ZMHCTableItemType_PANELIST"
    public static let panelistHeaderIdentifier = "ZMHCTableItemType_PANELIST_Group"

    /// Live scans request AXIdentifier only for roles whose identifiers are
    /// part of the parser contract. Some unrelated Zoom web-view nodes return
    /// a generic AX failure for this optional attribute.
    static func identifierIsRelevant(forRole role: String?) -> Bool {
        switch role {
        case "AXWindow", "AXButton", "AXMenuItem", "AXCell":
            true
        default:
            false
        }
    }

    public let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func parse(
        root: ZoomAXSnapshotNode,
        zoomRunning: Bool,
        version: String?,
        revealAttempted: Bool = false,
        scanTruncated: Bool = false,
        isReliable: Bool = true,
        warnings: [String] = []
    ) -> ZoomCaptureSnapshot {
        // Zoom presents the meeting and Participants panel as sibling windows.
        // First establish that a real meeting exists anywhere in the Zoom tree.
        var meetingSearch = MeetingSearchState(remainingNodes: limits.maximumNodes)
        searchForMeetingWindow(
            root,
            depth: 0,
            state: &meetingSearch
        )

        var participantSearch = ParticipantSearchState(remainingNodes: limits.maximumNodes)
        if meetingSearch.meetingDetected {
            visitParticipants(
                root,
                depth: 0,
                insideParticipantsList: false,
                state: &participantSearch
            )
        }

        let wasTruncated = scanTruncated
            || meetingSearch.truncated
            || participantSearch.truncated

        var allWarnings = warnings
        if wasTruncated {
            appendUnique(Self.truncationWarning, to: &allWarnings)
        }
        let resultIsReliable = isReliable && !wasTruncated
        if !isReliable {
            appendUnique(Self.incompleteReadWarning, to: &allWarnings)
        }

        return ZoomCaptureSnapshot(
            zoomRunning: zoomRunning,
            version: version,
            meetingDetected: meetingSearch.meetingDetected,
            panelDetected: participantSearch.panelDetected,
            names: participantSearch.names,
            revealAttempted: revealAttempted,
            scanTruncated: wasTruncated,
            warnings: allWarnings,
            meetingToken: meetingSearch.meetingToken,
            isReliable: resultIsReliable
        )
    }

    /// Returns a conservative action. An ambiguous button state is never pressed.
    public func revealDecision(
        root: ZoomAXSnapshotNode,
        meetingDetected: Bool,
        panelDetected: Bool,
        callerAllowsReveal: Bool,
        safeMenuFallbackAvailable: Bool = false
    ) -> ZoomRevealDecision {
        guard callerAllowsReveal, meetingDetected, !panelDetected else {
            return .none
        }

        var search = RevealSearchState(remainingNodes: limits.maximumNodes)
        search.foundSafeMenuFallback = safeMenuFallbackAvailable
        searchForRevealControls(
            root,
            depth: 0,
            insideMeetingWindow: false,
            state: &search
        )

        // An explicit open/close state wins over every possible fallback. It is
        // unsafe to press a menu item when Zoom already says the panel is open.
        if search.foundOpenParticipantButton {
            return .none
        }
        if search.foundClosedParticipantButton {
            return .pressParticipantButton
        }
        if search.foundSafeMenuFallback {
            return .pressShowParticipantsMenuItem
        }
        return .none
    }

    public static func participantButtonIsOpen(description: String?) -> Bool {
        let words = descriptionWords(description)
        return words.contains("opened") || words.contains("close")
    }

    public static func participantButtonIsClosed(description: String?) -> Bool {
        let words = descriptionWords(description)
        guard !participantButtonIsOpen(description: description) else {
            return false
        }
        return words.contains("closed") || words.contains("open")
    }
}

private extension ZoomAXTreeParser {
    static let truncationWarning = "Zoom accessibility scan reached its safety limit."
    static let incompleteReadWarning = "Zoom's accessibility tree could not be read completely."

    static func descriptionWords(_ description: String?) -> Set<String> {
        guard let description else { return [] }
        let normalized = description.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return Set(
            normalized
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    struct MeetingSearchState {
        var remainingNodes: Int
        var truncated = false
        var meetingDetected = false
        var meetingToken: String?
    }

    struct ParticipantSearchState {
        var remainingNodes: Int
        var truncated = false
        var panelDetected = false
        var names: [String] = []
    }

    struct RevealSearchState {
        var remainingNodes: Int
        var truncated = false
        var foundOpenParticipantButton = false
        var foundClosedParticipantButton = false
        var foundSafeMenuFallback = false
    }

    func searchForMeetingWindow(
        _ node: ZoomAXSnapshotNode,
        depth: Int,
        state: inout MeetingSearchState
    ) {
        guard !state.meetingDetected else { return }
        guard consumeNode(depth: depth, remainingNodes: &state.remainingNodes, truncated: &state.truncated) else {
            return
        }

        let isMeetingWindow = node.role == "AXWindow"
            && node.identifier == Self.meetingWindowIdentifier
        if isMeetingWindow {
            state.meetingDetected = true
            state.meetingToken = node.elementToken
            return
        }

        for child in node.children {
            searchForMeetingWindow(child, depth: depth + 1, state: &state)
            if state.meetingDetected { return }
        }
    }

    func visitParticipants(
        _ node: ZoomAXSnapshotNode,
        depth: Int,
        insideParticipantsList: Bool,
        state: inout ParticipantSearchState
    ) {
        guard consumeNode(depth: depth, remainingNodes: &state.remainingNodes, truncated: &state.truncated) else {
            return
        }

        let isParticipantsList = node.role == "AXOutline"
            && node.accessibilityDescription == Self.participantsListDescription
        let isInsideParticipantsList = insideParticipantsList || isParticipantsList
        if isParticipantsList {
            state.panelDetected = true
        }

        if node.role == "AXCell", node.identifier == Self.panelistCellIdentifier {
            // The stable row identifier remains usable when Zoom localizes or
            // omits the outline description.
            state.panelDetected = true
            if let name = firstStaticTextValue(
                in: node.children,
                depth: depth + 1,
                state: &state
            ) {
                state.names.append(name)
            }
            return
        }

        if isInsideParticipantsList, node.role == "AXCell" {
            // Headers, invitees, and unknown cell types are deliberately opaque.
            // Their descendant values are neither parsed nor visited.
            return
        }

        for child in node.children {
            visitParticipants(
                child,
                depth: depth + 1,
                insideParticipantsList: isInsideParticipantsList,
                state: &state
            )
        }
    }

    func firstStaticTextValue(
        in nodes: [ZoomAXSnapshotNode],
        depth: Int,
        state: inout ParticipantSearchState
    ) -> String? {
        for node in nodes {
            guard consumeNode(
                depth: depth,
                remainingNodes: &state.remainingNodes,
                truncated: &state.truncated
            ) else {
                return nil
            }

            if node.role == "AXStaticText", let value = node.value {
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    return name
                }
            }

            if let value = firstStaticTextValue(
                in: node.children,
                depth: depth + 1,
                state: &state
            ) {
                return value
            }
        }
        return nil
    }

    func searchForRevealControls(
        _ node: ZoomAXSnapshotNode,
        depth: Int,
        insideMeetingWindow: Bool,
        state: inout RevealSearchState
    ) {
        guard consumeNode(
            depth: depth,
            remainingNodes: &state.remainingNodes,
            truncated: &state.truncated
        ) else {
            return
        }

        let isMeetingWindow = node.role == "AXWindow"
            && node.identifier == Self.meetingWindowIdentifier
        let isInsideMeetingWindow = insideMeetingWindow || isMeetingWindow

        if isInsideMeetingWindow,
           node.role == "AXButton",
           node.identifier == Self.participantButtonIdentifier {
            if Self.participantButtonIsOpen(description: node.accessibilityDescription) {
                state.foundOpenParticipantButton = true
            } else if Self.participantButtonIsClosed(description: node.accessibilityDescription) {
                state.foundClosedParticipantButton = true
            }
        }

        if node.role == "AXMenuItem",
           node.identifier == Self.showParticipantsMenuIdentifier,
           node.title == Self.showParticipantsMenuTitle {
            state.foundSafeMenuFallback = true
        }

        for child in node.children {
            searchForRevealControls(
                child,
                depth: depth + 1,
                insideMeetingWindow: isInsideMeetingWindow,
                state: &state
            )
        }
    }

    func consumeNode(
        depth: Int,
        remainingNodes: inout Int,
        truncated: inout Bool
    ) -> Bool {
        guard depth <= limits.maximumDepth, remainingNodes > 0 else {
            truncated = true
            return false
        }
        remainingNodes -= 1
        return true
    }

    func appendUnique(_ warning: String, to warnings: inout [String]) {
        if !warnings.contains(warning) {
            warnings.append(warning)
        }
    }
}
