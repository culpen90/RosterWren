import Foundation

/// The immutable result of one bounded inspection of Zoom's accessibility tree.
public struct ZoomCaptureSnapshot: Equatable, Sendable {
    public let zoomRunning: Bool
    public let version: String?
    public let meetingDetected: Bool
    public let meetingToken: String?
    public let panelDetected: Bool
    public let names: [String]
    public let revealAttempted: Bool
    public let scanTruncated: Bool
    public let isReliable: Bool
    public let warnings: [String]

    public init(
        zoomRunning: Bool,
        version: String?,
        meetingDetected: Bool,
        panelDetected: Bool,
        names: [String],
        revealAttempted: Bool,
        scanTruncated: Bool,
        warnings: [String],
        meetingToken: String? = nil,
        isReliable: Bool = true
    ) {
        self.zoomRunning = zoomRunning
        self.version = version
        self.meetingDetected = meetingDetected
        self.meetingToken = meetingToken
        self.panelDetected = panelDetected
        self.names = names
        self.revealAttempted = revealAttempted
        self.scanTruncated = scanTruncated
        self.isReliable = isReliable && !scanTruncated
        self.warnings = warnings
    }
}
