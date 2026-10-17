import Foundation
import CoreGraphics

public enum PetIdentity {
    // Verified against this client's accessible mascot label. Never infer identity from window size.
    public static func matches(role: String, identifier: String, labels: [String]) -> Bool {
        guard ["AXImage", "AXGroup"].contains(role) else { return false }
        if identifier == "avatar-mascot-button" { return true }
        return labels.contains { label in
            let value = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.count < 150 && (value.hasSuffix(" pet") || value.hasSuffix(" 虚拟宠物") || value.hasSuffix(" 虛擬寵物"))
        }
    }
}

public enum Placement {
    /// Layout wrappers can retain their expanded height after their contents
    /// collapse. Preserve card padding, but never reserve empty wrapper space.
    public static func contentBounds(container: CGRect, contents: [CGRect], padding: CGFloat = 10) -> CGRect? {
        let visible = contents.map { $0.intersection(container) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard let first = visible.first else { return nil }
        let bounds = visible.dropFirst().reduce(first) { $0.union($1) }
        let top = max(container.minY, bounds.minY - padding)
        let bottom = min(container.maxY, bounds.maxY + padding)
        return CGRect(x: container.minX, y: top, width: container.width, height: bottom - top)
    }

    /// CG uses a top-left origin on the primary display; AppKit uses a bottom-left origin.
    public static func appKitRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    // The quota view has an 8 pt transparent edge, so 4 pt between window
    // bounds gives the same 12 pt visible gap as the toolbar/task-card stack.
    public static func frame(anchor: CGRect, occupied: CGRect? = nil, size: CGSize, screens: [CGRect], gap: CGFloat = 4, wasAbove: Bool = false) -> CGRect? {
        guard anchor.width > 0, anchor.height > 0, size.width > 0, size.height > 0,
              let screen = screens.max(by: { area($0.intersection(anchor)) < area($1.intersection(anchor)) }),
              area(screen.intersection(anchor)) > 0,
              screen.width >= size.width + 8, screen.height >= size.height + 8 else { return nil }
        let safe = screen.insetBy(dx: 4, dy: 4)
        let bounds = occupied.map { anchor.union($0) } ?? anchor
        let candidates = [
            CGRect(x: anchor.midX - size.width / 2, y: bounds.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: anchor.midX - size.width / 2, y: bounds.maxY + gap, width: size.width, height: size.height)
        ]
        let aboveFits = candidates[1].minY >= safe.minY && candidates[1].maxY <= safe.maxY
        for (index, candidate) in candidates.enumerated() {
            // Do not clamp the vertical position into a card or the pet. Leave
            // a little extra room before switching back down to prevent jitter.
            let margin: CGFloat = index == 0 && wasAbove && aboveFits ? 16 : 0
            guard candidate.minY >= safe.minY + margin, candidate.maxY <= safe.maxY else { continue }
            let adjusted = CGRect(
                x: min(max(candidate.minX, safe.minX), safe.maxX - size.width),
                y: candidate.minY,
                width: size.width, height: size.height)
            if !adjusted.intersects(bounds.insetBy(dx: -gap / 2, dy: -gap / 2)) { return adjusted }
        }
        return nil
    }

    /// Bounds come only from semantic controls/text in the confirmed pet
    /// overlay, never from unrelated windows or the full-screen overlay frame.
    public static func occupiedBounds(pet: CGRect, elements: [CGRect]) -> CGRect {
        let nearby = elements.filter { rect in
            rect.minX.isFinite && rect.minY.isFinite && rect.width > 0 && rect.height > 0 &&
            rect.width <= max(700, pet.width * 8) && rect.height <= 700 && rect.maxX >= pet.minX - 180 && rect.minX <= pet.maxX + 180 &&
            abs(rect.midY - pet.midY) < 700
        }
        var occupied = pet
        var remaining = nearby
        for _ in 0..<12 {
            let connected = remaining.filter { occupied.insetBy(dx: -28, dy: -44).intersects($0) }
            guard !connected.isEmpty else { break }
            // contentBounds already preserves the visible card padding. Do
            // not add another vertical inset on top of the placement gap.
            for rect in connected { occupied = occupied.union(rect.insetBy(dx: -12, dy: 0)) }
            remaining.removeAll { connected.contains($0) }
        }
        return occupied
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
}
