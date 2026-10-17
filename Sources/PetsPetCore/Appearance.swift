import Foundation

public enum AppearancePreference: String, CaseIterable {
    case system, light, dark

    public init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .system }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}
