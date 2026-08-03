import Foundation

/// A value-only accessibility-tree fixture. Live `AXUIElement` references never
/// escape the main-actor client.
public struct ZoomAXSnapshotNode: Equatable, Sendable {
    public let role: String?
    public let identifier: String?
    public let title: String?
    public let value: String?
    public let accessibilityDescription: String?
    public let elementToken: String?
    public let children: [ZoomAXSnapshotNode]

    public init(
        role: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        value: String? = nil,
        accessibilityDescription: String? = nil,
        elementToken: String? = nil,
        children: [ZoomAXSnapshotNode] = []
    ) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.value = value
        self.accessibilityDescription = accessibilityDescription
        self.elementToken = elementToken
        self.children = children
    }
}
