import Foundation

public enum ComponentPosition: String, CaseIterable {
    case followPet, sidebarBottom

    public static let defaultsKey = "componentPosition"
    public init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .followPet }
    public var title: String { self == .followPet ? "跟随宠物（默认）" : "侧栏底部" }
}
