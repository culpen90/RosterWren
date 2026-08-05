import XCTest
@testable import RosterWren

final class ZoomAXTreeParserTests: XCTestCase {
    private let parser = ZoomAXTreeParser()

    func testIdentifierReadPolicyCoversOnlyRolesUsedByParser() {
        for role in ["AXWindow", "AXButton", "AXMenuItem", "AXCell"] {
            XCTAssertTrue(
                ZoomAXTreeParser.identifierIsRelevant(forRole: role),
                "Expected identifiers to be relevant for \(role)"
            )
        }

        for role in [nil, "AXApplication", "AXUnknown", "AXGroup", "AXOutline", "AXStaticText"] {
            XCTAssertFalse(
                ZoomAXTreeParser.identifierIsRelevant(forRole: role),
                "Expected identifiers to be irrelevant for \(role ?? "nil")"
            )
        }
    }

    func testExtractsFirstStaticTextFromPanelistCellsAndPreservesDuplicates() {
        let root = application(children: [
            meetingWindow(children: []),
            participantWindow(children: [
                participantsList(children: [
                    panelistCell(name: "Alex"),
                    panelistCell(name: "Blair", trailingText: "Muted"),
                    panelistCell(name: "Alex")
                ])
            ])
        ])

        let result = parser.parse(root: root, zoomRunning: true, version: "6.5.0")

        XCTAssertTrue(result.zoomRunning)
        XCTAssertEqual(result.version, "6.5.0")
        XCTAssertTrue(result.meetingDetected)
        XCTAssertEqual(result.meetingToken, "fixture-meeting-window")
        XCTAssertTrue(result.panelDetected)
        XCTAssertEqual(result.names, ["Alex", "Blair", "Alex"])
        XCTAssertFalse(result.revealAttempted)
        XCTAssertFalse(result.scanTruncated)
        XCTAssertTrue(result.isReliable)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testFindsParticipantsListInSiblingWindowEvenWhenItPrecedesMeetingWindow() {
        let root = application(children: [
            participantWindow(children: [
                participantsList(children: [panelistCell(name: "Sibling attendee")])
            ]),
            meetingWindow(children: [])
        ])

        let result = parser.parse(root: root, zoomRunning: true, version: nil)

        XCTAssertTrue(result.meetingDetected)
        XCTAssertTrue(result.panelDetected)
        XCTAssertEqual(result.names, ["Sibling attendee"])
    }

    func testTraversesUnrelatedUnknownNodesWithoutUsingThemAsRosterEvidence() {
        let root = application(children: [
            .init(
                role: "AXUnknown",
                children: [.init(role: "AXGroup", children: [])]
            ),
            meetingWindow(children: []),
            participantWindow(children: [
                participantsList(children: [panelistCell(name: "Casey")])
            ])
        ])

        let result = parser.parse(root: root, zoomRunning: true, version: "7.1.0")

        XCTAssertTrue(result.meetingDetected)
        XCTAssertTrue(result.panelDetected)
        XCTAssertEqual(result.names, ["Casey"])
        XCTAssertTrue(result.isReliable)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testExcludesHeaderInviteesAndTextOutsidePanelistCells() {
        let header = ZoomAXSnapshotNode(
            role: "AXCell",
            identifier: ZoomAXTreeParser.panelistHeaderIdentifier,
            children: [.init(role: "AXStaticText", value: "Panelists (2)")]
        )
        let invitee = ZoomAXSnapshotNode(
            role: "AXCell",
            identifier: "ZMHCTableItemType_INVITEE",
            children: [.init(role: "AXStaticText", value: "Private invitee")]
        )
        let unrelated = ZoomAXSnapshotNode(role: "AXStaticText", value: "Meeting topic")
        let root = meetingWindow(children: [
            unrelated,
            participantsList(children: [header, invitee, panelistCell(name: "Casey")])
        ])

        let result = parser.parse(root: root, zoomRunning: true, version: nil)

        XCTAssertEqual(result.names, ["Casey"])
    }

    func testMeetingAndPanelDetectionRequireExactZoomEvidence() {
        let impostor = ZoomAXSnapshotNode(
            role: "AXWindow",
            identifier: "zm.meeting.window.other",
            children: [participantsList(children: [panelistCell(name: "Dana")])]
        )

        let missing = parser.parse(root: impostor, zoomRunning: true, version: nil)
        XCTAssertFalse(missing.meetingDetected)
        XCTAssertFalse(missing.panelDetected)
        XCTAssertEqual(missing.names, [])

        let meetingWithoutPanel = parser.parse(
            root: meetingWindow(children: []),
            zoomRunning: true,
            version: nil
        )
        XCTAssertTrue(meetingWithoutPanel.meetingDetected)
        XCTAssertFalse(meetingWithoutPanel.panelDetected)
    }

    func testMeetingTokenComesFromExactMeetingWindow() {
        let root = application(children: [
            .init(
                role: "AXWindow",
                identifier: "zm.meeting.window.other",
                elementToken: "impostor-token"
            ),
            meetingWindow(token: "real-meeting-token", children: [])
        ])

        let result = parser.parse(root: root, zoomRunning: true, version: nil)

        XCTAssertTrue(result.meetingDetected)
        XCTAssertEqual(result.meetingToken, "real-meeting-token")
        XCTAssertTrue(result.isReliable)
    }

    func testUpstreamReadFailureMarksOtherwiseCompleteParseUnreliable() {
        let result = parser.parse(
            root: meetingWindow(children: []),
            zoomRunning: true,
            version: nil,
            isReliable: false
        )

        XCTAssertTrue(result.meetingDetected)
        XCTAssertFalse(result.scanTruncated)
        XCTAssertFalse(result.isReliable)
        XCTAssertEqual(
            result.warnings,
            ["Zoom's accessibility tree could not be read completely."]
        )
    }

    func testStablePanelistCellWorksWhenOutlineDescriptionIsLocalized() {
        let localizedList = ZoomAXSnapshotNode(
            role: "AXOutline",
            accessibilityDescription: "Liste des participants",
            children: [panelistCell(name: "Élodie")]
        )
        let root = application(children: [
            meetingWindow(children: []),
            .init(role: "AXWindow", children: [localizedList])
        ])

        let result = parser.parse(root: root, zoomRunning: true, version: nil)

        XCTAssertTrue(result.meetingDetected)
        XCTAssertTrue(result.panelDetected)
        XCTAssertEqual(result.names, ["Élodie"])
    }

    func testRevealDecisionPressesOnlyExplicitlyClosedParticipantButton() {
        let closed = application(children: [
            meetingWindow(children: [
                .init(
                    role: "AXButton",
                    identifier: ZoomAXTreeParser.participantButtonIdentifier,
                    accessibilityDescription: "Participants, closed. Open participants"
                )
            ])
        ])

        XCTAssertEqual(
            parser.revealDecision(
                root: closed,
                meetingDetected: true,
                panelDetected: false,
                callerAllowsReveal: true
            ),
            .pressParticipantButton
        )
        XCTAssertEqual(
            parser.revealDecision(
                root: closed,
                meetingDetected: true,
                panelDetected: false,
                callerAllowsReveal: false
            ),
            .none
        )
    }

    func testRevealDecisionDoesNotCloseAnOpenPanel() {
        let open = application(children: [
            meetingWindow(children: [
                .init(
                    role: "AXButton",
                    identifier: ZoomAXTreeParser.participantButtonIdentifier,
                    accessibilityDescription: "Participants, opened. Close participants"
                )
            ]),
            safeMenuItem()
        ])

        XCTAssertEqual(
            parser.revealDecision(
                root: open,
                meetingDetected: true,
                panelDetected: false,
                callerAllowsReveal: true,
                safeMenuFallbackAvailable: true
            ),
            .none
        )
    }

    func testRevealDecisionUsesOnlyExactSafeMenuFallback() {
        let ambiguousButtonAndSafeMenu = application(children: [
            meetingWindow(children: [
                .init(
                    role: "AXButton",
                    identifier: ZoomAXTreeParser.participantButtonIdentifier,
                    accessibilityDescription: "Participants"
                )
            ]),
            safeMenuItem()
        ])

        XCTAssertEqual(
            parser.revealDecision(
                root: ambiguousButtonAndSafeMenu,
                meetingDetected: true,
                panelDetected: false,
                callerAllowsReveal: true
            ),
            .pressShowParticipantsMenuItem
        )

        let wrongTitle = application(children: [
            meetingWindow(children: []),
            .init(
                role: "AXMenuItem",
                identifier: ZoomAXTreeParser.showParticipantsMenuIdentifier,
                title: "Hide participants"
            )
        ])
        XCTAssertEqual(
            parser.revealDecision(
                root: wrongTitle,
                meetingDetected: true,
                panelDetected: false,
                callerAllowsReveal: true
            ),
            .none
        )
    }

    func testRevealDecisionUsesSafeMenuFallbackDiscoveredOutsideRosterTree() {
        let root = application(children: [meetingWindow(children: [])])

        XCTAssertEqual(
            parser.revealDecision(
                root: root,
                meetingDetected: true,
                panelDetected: false,
                callerAllowsReveal: true,
                safeMenuFallbackAvailable: true
            ),
            .pressShowParticipantsMenuItem
        )
    }

    func testRevealDecisionRequiresMeetingAndHiddenPanel() {
        let root = application(children: [meetingWindow(children: []), safeMenuItem()])

        XCTAssertEqual(
            parser.revealDecision(
                root: root,
                meetingDetected: false,
                panelDetected: false,
                callerAllowsReveal: true
            ),
            .none
        )
        XCTAssertEqual(
            parser.revealDecision(
                root: root,
                meetingDetected: true,
                panelDetected: true,
                callerAllowsReveal: true
            ),
            .none
        )
    }

    func testNodeLimitMarksCaptureTruncatedWithoutReadingPastBound() {
        let limitedParser = ZoomAXTreeParser(
            limits: .init(maximumNodes: 2, maximumDepth: 40)
        )
        let root = application(children: [
            meetingWindow(children: [participantsList(children: [panelistCell(name: "Eli")])])
        ])

        let result = limitedParser.parse(root: root, zoomRunning: true, version: nil)

        XCTAssertTrue(result.meetingDetected)
        XCTAssertFalse(result.panelDetected)
        XCTAssertEqual(result.names, [])
        XCTAssertTrue(result.scanTruncated)
        XCTAssertFalse(result.isReliable)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testDepthLimitMarksCaptureTruncated() {
        let limitedParser = ZoomAXTreeParser(
            limits: .init(maximumNodes: 100, maximumDepth: 1)
        )
        let root = application(children: [
            .init(role: "AXGroup", children: [meetingWindow(children: [])])
        ])

        let result = limitedParser.parse(root: root, zoomRunning: true, version: nil)

        XCTAssertFalse(result.meetingDetected)
        XCTAssertTrue(result.scanTruncated)
        XCTAssertFalse(result.isReliable)
    }
}

private extension ZoomAXTreeParserTests {
    func application(children: [ZoomAXSnapshotNode]) -> ZoomAXSnapshotNode {
        .init(role: "AXApplication", children: children)
    }

    func meetingWindow(
        token: String? = "fixture-meeting-window",
        children: [ZoomAXSnapshotNode]
    ) -> ZoomAXSnapshotNode {
        .init(
            role: "AXWindow",
            identifier: ZoomAXTreeParser.meetingWindowIdentifier,
            elementToken: token,
            children: children
        )
    }

    func participantsList(children: [ZoomAXSnapshotNode]) -> ZoomAXSnapshotNode {
        .init(
            role: "AXOutline",
            accessibilityDescription: ZoomAXTreeParser.participantsListDescription,
            children: children
        )
    }

    func participantWindow(children: [ZoomAXSnapshotNode]) -> ZoomAXSnapshotNode {
        .init(role: "AXWindow", identifier: "zoom.participants.window", children: children)
    }

    func panelistCell(name: String, trailingText: String? = nil) -> ZoomAXSnapshotNode {
        var children: [ZoomAXSnapshotNode] = [
            .init(
                role: "AXGroup",
                children: [.init(role: "AXStaticText", value: "  \(name)  ")]
            )
        ]
        if let trailingText {
            children.append(.init(role: "AXStaticText", value: trailingText))
        }
        return .init(
            role: "AXCell",
            identifier: ZoomAXTreeParser.panelistCellIdentifier,
            children: children
        )
    }

    func safeMenuItem() -> ZoomAXSnapshotNode {
        .init(
            role: "AXMenuItem",
            identifier: ZoomAXTreeParser.showParticipantsMenuIdentifier,
            title: ZoomAXTreeParser.showParticipantsMenuTitle
        )
    }
}
