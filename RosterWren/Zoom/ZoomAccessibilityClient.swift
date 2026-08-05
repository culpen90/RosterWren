import AppKit
import ApplicationServices
import Foundation
import OSLog

private let zoomAXLogger = Logger(
    subsystem: "com.rosterwren.RosterWren",
    category: "ZoomAccessibility"
)

/// Discovers Zoom on the main actor, then delegates bounded Accessibility work
/// to a utility task so a stalled Zoom process cannot freeze the app's UI.
@MainActor
public final class ZoomAccessibilityClient {
    private let parser: ZoomAXTreeParser

    public init(limits: ZoomAXTreeParser.Limits = .init()) {
        parser = ZoomAXTreeParser(limits: limits)
    }

    /// Checks trust and optionally asks macOS to show its Accessibility prompt.
    @discardableResult
    public func requestAccessibilityAccess(prompt: Bool = true) -> Bool {
        // The SDK exposes kAXTrustedCheckOptionPrompt as mutable global state,
        // which Swift 6 correctly rejects. Its documented string value avoids
        // crossing that unsafe global boundary.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Performs one bounded capture. If a reveal is safely attempted, the panel
    /// is picked up by a later coordinator scan after Zoom updates its UI.
    public func captureParticipants(
        allowReveal: Bool = false
    ) async -> ZoomCaptureSnapshot {
        guard !Task.isCancelled else {
            return Self.cancelledSnapshot(zoomRunning: false, version: nil)
        }
        guard let zoom = NSRunningApplication.runningApplications(
            withBundleIdentifier: ZoomAXTreeParser.zoomBundleIdentifier
        ).first(where: { !$0.isTerminated }) else {
            return ZoomCaptureSnapshot(
                zoomRunning: false,
                version: nil,
                meetingDetected: false,
                panelDetected: false,
                names: [],
                revealAttempted: false,
                scanTruncated: false,
                warnings: []
            )
        }

        let version = zoomVersion(for: zoom)
        guard requestAccessibilityAccess(prompt: false) else {
            return ZoomCaptureSnapshot(
                zoomRunning: true,
                version: version,
                meetingDetected: false,
                panelDetected: false,
                names: [],
                revealAttempted: false,
                scanTruncated: false,
                warnings: ["Accessibility permission is required to inspect Zoom."],
                isReliable: false
            )
        }

        let worker = ZoomAccessibilityWorker(
            parser: parser,
            version: version,
            allowReveal: allowReveal
        )
        let processIdentifier = zoom.processIdentifier
        let captureTask = Task.detached(priority: .utility) {
            worker.capture(processIdentifier: processIdentifier)
        }
        return await withTaskCancellationHandler {
            await captureTask.value
        } onCancel: {
            captureTask.cancel()
        }
    }
}

private extension ZoomAccessibilityClient {
    static func cancelledSnapshot(zoomRunning: Bool, version: String?) -> ZoomCaptureSnapshot {
        ZoomCaptureSnapshot(
            zoomRunning: zoomRunning,
            version: version,
            meetingDetected: false,
            panelDetected: false,
            names: [],
            revealAttempted: false,
            scanTruncated: false,
            warnings: ["Zoom accessibility scan was cancelled."],
            isReliable: false
        )
    }

    func zoomVersion(for application: NSRunningApplication) -> String? {
        guard application.bundleIdentifier == ZoomAXTreeParser.zoomBundleIdentifier,
              let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        return (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
}

/// Performs all cross-process AX work off the main actor. Every non-Sendable
/// AXUIElement is created, used, and released inside this worker call.
private struct ZoomAccessibilityWorker: Sendable {
    let parser: ZoomAXTreeParser
    let version: String?
    let allowReveal: Bool

    func capture(processIdentifier: pid_t) -> ZoomCaptureSnapshot {
        guard !Task.isCancelled else {
            return cancelledSnapshot()
        }
        let appElement = AXUIElementCreateApplication(processIdentifier)
        // Bounds each cross-process Accessibility request if Zoom is stalled.
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        var builder = LiveTreeBuilder(
            limits: parser.limits,
            processIdentifier: processIdentifier
        )
        guard let root = builder.snapshot(element: appElement) else {
            if builder.cancelled || Task.isCancelled {
                return cancelledSnapshot()
            }
            return ZoomCaptureSnapshot(
                zoomRunning: true,
                version: version,
                meetingDetected: false,
                panelDetected: false,
                names: [],
                revealAttempted: false,
                scanTruncated: builder.truncated,
                warnings: ["Zoom's accessibility tree was unavailable."],
                isReliable: false
            )
        }

        let initial = parser.parse(
            root: root,
            zoomRunning: true,
            version: version,
            scanTruncated: builder.truncated,
            isReliable: builder.isReliable
        )
        guard !builder.cancelled, !Task.isCancelled else {
            return cancelledSnapshot()
        }
        if allowReveal,
           initial.isReliable,
           initial.meetingDetected,
           !initial.panelDetected {
            builder.findShowParticipantsMenuItem(from: appElement)
        }
        guard !builder.cancelled, !Task.isCancelled else {
            return cancelledSnapshot()
        }
        let decision = parser.revealDecision(
            root: root,
            meetingDetected: initial.meetingDetected,
            panelDetected: initial.panelDetected,
            callerAllowsReveal: allowReveal && initial.isReliable,
            safeMenuFallbackAvailable: builder.showParticipantsMenuItem != nil
        )

        var revealAttempted = false
        var warnings = initial.warnings
        switch decision {
        case .none:
            break
        case .pressParticipantButton:
            revealAttempted = performPress(
                on: builder.closedParticipantButton,
                failureWarning: "Zoom's participant control could not be opened.",
                warnings: &warnings
            )
        case .pressShowParticipantsMenuItem:
            revealAttempted = performPress(
                on: builder.showParticipantsMenuItem,
                failureWarning: "Zoom's Show participants menu item could not be opened.",
                warnings: &warnings
            )
        }

        guard !Task.isCancelled else {
            return cancelledSnapshot()
        }

        return ZoomCaptureSnapshot(
            zoomRunning: initial.zoomRunning,
            version: initial.version,
            meetingDetected: initial.meetingDetected,
            panelDetected: initial.panelDetected,
            names: initial.names,
            revealAttempted: revealAttempted,
            scanTruncated: initial.scanTruncated,
            warnings: warnings,
            meetingToken: initial.meetingToken,
            isReliable: initial.isReliable
        )
    }

    func performPress(
        on element: AXUIElement?,
        failureWarning: String,
        warnings: inout [String]
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let element else {
            appendUnique(failureWarning, to: &warnings)
            return false
        }
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else {
            appendUnique(failureWarning, to: &warnings)
            // The action reached Zoom even when Zoom rejected it; callers use
            // this flag to avoid immediately retrying the same reveal.
            return true
        }
        return true
    }

    func cancelledSnapshot() -> ZoomCaptureSnapshot {
        ZoomCaptureSnapshot(
            zoomRunning: true,
            version: version,
            meetingDetected: false,
            panelDetected: false,
            names: [],
            revealAttempted: false,
            scanTruncated: false,
            warnings: ["Zoom accessibility scan was cancelled."],
            isReliable: false
        )
    }

    func appendUnique(_ warning: String, to warnings: inout [String]) {
        if !warnings.contains(warning) {
            warnings.append(warning)
        }
    }
}

private struct LiveTreeBuilder {
    let limits: ZoomAXTreeParser.Limits
    let processIdentifier: pid_t
    var remainingNodes: Int
    var truncated = false
    var isReliable = true
    var cancelled = false
    var closedParticipantButton: AXUIElement?
    var showParticipantsMenuItem: AXUIElement?
    var visitedElements: [AXUIElement] = []

    init(limits: ZoomAXTreeParser.Limits, processIdentifier: pid_t) {
        self.limits = limits
        self.processIdentifier = processIdentifier
        remainingNodes = limits.maximumNodes
    }

    mutating func snapshot(
        element: AXUIElement,
        depth: Int = 0,
        insideMeetingWindow: Bool = false,
        insideParticipantsList: Bool = false,
        insidePanelistCell: Bool = false
    ) -> ZoomAXSnapshotNode? {
        guard !Task.isCancelled else {
            cancelled = true
            isReliable = false
            return nil
        }
        guard depth <= limits.maximumDepth, remainingNodes > 0 else {
            truncated = true
            return nil
        }
        guard !visitedElements.contains(where: { CFEqual($0, element) }) else {
            return nil
        }
        visitedElements.append(element)
        remainingNodes -= 1

        let role = stringAttribute(
            kAXRoleAttribute,
            from: element,
            required: true
        )
        if depth == 0, let role, role != "AXApplication" {
            markUnreliableType(
                attribute: kAXRoleAttribute,
                element: element,
                detail: "unexpected-root-role"
            )
        }
        let identifier = ZoomAXTreeParser.identifierIsRelevant(forRole: role)
            ? stringAttribute(
                kAXIdentifierAttribute,
                from: element
            )
            : nil
        let isParticipantButton = role == "AXButton"
            && identifier == ZoomAXTreeParser.participantButtonIdentifier
        let isShowParticipantsMenuItem = role == "AXMenuItem"
            && identifier == ZoomAXTreeParser.showParticipantsMenuIdentifier

        // Zoom exposes the state/list markers in AXDescription. Avoid reading
        // descriptions from unrelated controls.
        let accessibilityDescription: String?
        if isParticipantButton || role == "AXOutline" {
            accessibilityDescription = stringAttribute(
                kAXDescriptionAttribute,
                from: element
            )
        } else {
            accessibilityDescription = nil
        }
        let title = isShowParticipantsMenuItem
            ? stringAttribute(
                kAXTitleAttribute,
                from: element
            )
            : nil
        let isMeetingWindow = role == "AXWindow"
            && identifier == ZoomAXTreeParser.meetingWindowIdentifier
        let elementToken: String?
        if isMeetingWindow,
           let windowNumber = copyAttribute(
               "AXWindowNumber",
               from: element
           ) as? NSNumber {
            elementToken = "\(processIdentifier):window:\(windowNumber.int64Value)"
        } else if isMeetingWindow {
            elementToken = "\(processIdentifier):element:\(String(CFHash(element), radix: 16))"
        } else {
            elementToken = nil
        }
        let isInsideMeetingWindow = insideMeetingWindow || isMeetingWindow
        let isParticipantsList = role == "AXOutline"
            && accessibilityDescription == ZoomAXTreeParser.participantsListDescription
        let isInsideParticipantsList = insideParticipantsList || isParticipantsList
        let isPanelistCell = role == "AXCell"
            && identifier == ZoomAXTreeParser.panelistCellIdentifier
        let isInsidePanelistCell = insidePanelistCell || isPanelistCell

        // AXValue is the only attribute this client treats as a participant-name
        // source, and it is never requested outside a confirmed panelist cell.
        let value: String?
        if isInsidePanelistCell, role == "AXStaticText" {
            value = stringAttribute(
                kAXValueAttribute,
                from: element
            )
        } else {
            value = nil
        }

        if isInsideMeetingWindow,
           isParticipantButton,
           ZoomAXTreeParser.participantButtonIsClosed(description: accessibilityDescription),
           closedParticipantButton == nil {
            closedParticipantButton = element
        }

        if isShowParticipantsMenuItem,
           title == ZoomAXTreeParser.showParticipantsMenuTitle,
           showParticipantsMenuItem == nil {
            showParticipantsMenuItem = element
        }

        var children: [ZoomAXSnapshotNode] = []
        for child in elementChildren(
            of: element,
            isApplicationRoot: depth == 0
        ) {
            guard remainingNodes > 0 else {
                truncated = true
                break
            }
            if let childSnapshot = snapshot(
                element: child,
                depth: depth + 1,
                insideMeetingWindow: isInsideMeetingWindow,
                insideParticipantsList: isInsideParticipantsList,
                insidePanelistCell: isInsidePanelistCell
            ) {
                children.append(childSnapshot)
            }
        }

        return ZoomAXSnapshotNode(
            role: role,
            identifier: identifier,
            title: title,
            value: value,
            accessibilityDescription: accessibilityDescription,
            elementToken: elementToken,
            children: children
        )
    }

    private mutating func stringAttribute(
        _ name: String,
        from element: AXUIElement,
        affectsReliability: Bool = true,
        required: Bool = false
    ) -> String? {
        guard let value = copyAttribute(
            name,
            from: element,
            affectsReliability: affectsReliability,
            required: required
        ) else {
            return nil
        }
        guard let string = value as? String else {
            if affectsReliability {
                markUnreliableType(
                    attribute: name,
                    element: element,
                    detail: "unexpected-type"
                )
            }
            return nil
        }
        return string
    }

    private mutating func elementChildren(
        of element: AXUIElement,
        isApplicationRoot: Bool
    ) -> [AXUIElement] {
        if isApplicationRoot {
            return elementArrayAttribute(
                kAXWindowsAttribute,
                from: element,
                required: true
            )
        }
        return elementArrayAttribute(kAXChildrenAttribute, from: element)
    }

    private mutating func elementArrayAttribute(
        _ name: String,
        from element: AXUIElement,
        affectsReliability: Bool = true,
        required: Bool = false
    ) -> [AXUIElement] {
        guard let value = copyAttribute(
            name,
            from: element,
            affectsReliability: affectsReliability,
            required: required
        ) else {
            return []
        }
        guard let elements = value as? [AXUIElement] else {
            if affectsReliability {
                markUnreliableType(
                    attribute: name,
                    element: element,
                    detail: "unexpected-type"
                )
            }
            return []
        }
        return elements
    }

    /// Searches the optional menu fallback outside the roster snapshot. Menu
    /// failures, depth, and node limits can suppress reveal for this pass, but
    /// can never invalidate or contribute roster evidence.
    mutating func findShowParticipantsMenuItem(from application: AXUIElement) {
        guard showParticipantsMenuItem == nil,
              let menuBarValue = copyAttribute(
                  kAXMenuBarAttribute,
                  from: application,
                  affectsReliability: false
              ),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return
        }

        let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)
        var remainingRevealNodes = limits.maximumNodes
        var visitedRevealElements: [AXUIElement] = []
        searchRevealMenu(
            element: menuBar,
            depth: 0,
            remainingNodes: &remainingRevealNodes,
            visitedElements: &visitedRevealElements
        )
    }

    private mutating func searchRevealMenu(
        element: AXUIElement,
        depth: Int,
        remainingNodes: inout Int,
        visitedElements: inout [AXUIElement]
    ) {
        guard !Task.isCancelled else {
            cancelled = true
            isReliable = false
            return
        }
        guard showParticipantsMenuItem == nil,
              depth <= limits.maximumDepth,
              remainingNodes > 0,
              !visitedElements.contains(where: { CFEqual($0, element) }) else {
            return
        }
        visitedElements.append(element)
        remainingNodes -= 1

        let role = stringAttribute(
            kAXRoleAttribute,
            from: element,
            affectsReliability: false
        )
        if role == "AXMenuItem",
           stringAttribute(
               kAXIdentifierAttribute,
               from: element,
               affectsReliability: false
           ) == ZoomAXTreeParser.showParticipantsMenuIdentifier,
           stringAttribute(
               kAXTitleAttribute,
               from: element,
               affectsReliability: false
           ) == ZoomAXTreeParser.showParticipantsMenuTitle {
            showParticipantsMenuItem = element
            return
        }

        for child in elementArrayAttribute(
            kAXChildrenAttribute,
            from: element,
            affectsReliability: false
        ) {
            searchRevealMenu(
                element: child,
                depth: depth + 1,
                remainingNodes: &remainingNodes,
                visitedElements: &visitedElements
            )
            if showParticipantsMenuItem != nil || cancelled {
                return
            }
        }
    }

    private mutating func copyAttribute(
        _ name: String,
        from element: AXUIElement,
        affectsReliability: Bool = true,
        required: Bool = false
    ) -> CFTypeRef? {
        guard !Task.isCancelled else {
            cancelled = true
            isReliable = false
            return nil
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else {
            if affectsReliability {
                let isHardFailure: Bool
                switch error {
                case .failure, .illegalArgument, .invalidUIElement, .cannotComplete,
                     .notImplemented, .apiDisabled:
                    isHardFailure = true
                default:
                    isHardFailure = false
                }
                if required || isHardFailure {
                    zoomAXLogger.error(
                        "AX read failed: attribute=\(name, privacy: .public) error=\(error.rawValue, privacy: .public) element=\(CFHash(element), privacy: .public)"
                    )
                    isReliable = false
                }
            }
            if Task.isCancelled {
                cancelled = true
                isReliable = false
            }
            return nil
        }
        return value
    }

    private mutating func markUnreliableType(
        attribute: String,
        element: AXUIElement,
        detail: String
    ) {
        zoomAXLogger.error(
            "AX read failed: attribute=\(attribute, privacy: .public) error=\(detail, privacy: .public) element=\(CFHash(element), privacy: .public)"
        )
        isReliable = false
    }
}
