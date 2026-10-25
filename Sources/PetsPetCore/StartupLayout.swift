import Foundation

public enum StartupLayout {
    /// Saved window geometry can outlive a disconnected display or changed resolution.
    public static func frame(previous: CGRect?, screens: [CGRect], preferred: CGRect?) -> CGRect {
        let screens = screens.filter { valid($0) }
        let fallback = preferred.flatMap { valid($0) ? $0 : nil } ?? screens.first ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let previous = previous.flatMap { valid($0) ? $0 : nil }
        let screen = previous.flatMap { previous in
            screens.max { overlap(previous, $0) < overlap(previous, $1) }.flatMap { overlap(previous, $0) > 0 ? $0 : nil }
        } ?? fallback
        guard let previous else {
            let size = CGSize(width: min(1200, screen.width * 0.8), height: min(850, screen.height * 0.8))
            return CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        }
        let width = min(previous.width, screen.width), height = min(previous.height, screen.height)
        return CGRect(x: min(max(previous.minX, screen.minX), screen.maxX - width),
                      y: min(max(previous.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }

    public static func valid(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width >= 1 && frame.height >= 1
    }

    private static func overlap(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
