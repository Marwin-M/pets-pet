import AppKit
import SwiftUI
import PetsPetCore

final class DisplayModel: ObservableObject {
    @Published var snapshot: QuotaSnapshot?
    @Published var loading = true
    @Published var error: String?
    @Published var now = Date()
    @Published var appearance: AppearancePreference = .system
}

enum QuotaLayout {
    static let body = CGSize(width: 128, height: 64)
    static let ring: CGFloat = 44
    // Reference ring centers are 78 px apart with a 26 px track radius.
    static let gap: CGFloat = 22
    static let stroke: CGFloat = 5.5
    // Mirror two 250° C tracks with their 110° openings facing each other.
    static let arcFraction: CGFloat = 250.0 / 360.0
    static let arcStartDegrees: Double = -125
}

struct QuotaView: View {
    static let size = CGSize(width: QuotaLayout.body.width + 16, height: QuotaLayout.body.height + 16)
    @ObservedObject var model: DisplayModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { model.appearance == .dark || model.appearance == .system && colorScheme == .dark }

    var body: some View {
        ZStack {
            WaistedCapsule().fill((dark ? Color(red: 0.07, green: 0.10, blue: 0.16) : .white).opacity(reduceTransparency ? 1 : dark ? 0.88 : 0.60))
            WaistedCapsule().fill(LinearGradient(colors: [Color(red: 0.67, green: 0.84, blue: 0.88).opacity(dark ? 0.05 : 0.22), Color(red: 0.37, green: 0.58, blue: 1).opacity(dark ? 0.12 : 0.23)], startPoint: .leading, endPoint: .trailing))
            WaistedCapsule().fill(LinearGradient(colors: [.white.opacity(dark ? 0.08 : 0.20), .clear], startPoint: .top, endPoint: .center))
            TaijiBaseOutline().fill(LinearGradient(stops: [
                .init(color: .white.opacity(0.14), location: 0),
                .init(color: .white.opacity(0.14), location: 0.24),
                .init(color: .clear, location: 0.48),
                .init(color: .black.opacity(0.04), location: 0.62),
                .init(color: .black.opacity(0.08), location: 0.76),
                .init(color: .black.opacity(0.08), location: 1)
            ], startPoint: .leading, endPoint: .trailing))
            BetweenRingsCurve()
                .stroke(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.08), location: 0.056),
                    .init(color: .white.opacity(0.30), location: 0.153),
                    .init(color: .white.opacity(0.38), location: 0.278),
                    .init(color: .white.opacity(0.46), location: 0.50),
                    .init(color: .white.opacity(0.38), location: 0.722),
                    .init(color: .white.opacity(0.30), location: 0.847),
                    .init(color: .white.opacity(0.08), location: 0.944),
                    .init(color: .clear, location: 1)
                ], startPoint: BetweenRingsCurve.gradientStart, endPoint: BetweenRingsCurve.gradientEnd), lineWidth: 1.7)
            HStack(spacing: QuotaLayout.gap) {
                ring("5H", window: model.snapshot?.fiveHour, color: Color(red: 0.14, green: 0.78, blue: 0.59))
                ring("W", window: model.snapshot?.weekly, color: Color(red: 0.10, green: 0.48, blue: 1))
            }
            Text("5H").position(x: QuotaLayout.body.width / 2, y: 11).accessibilityHidden(true)
            Text("W").position(x: QuotaLayout.body.width / 2, y: 53).accessibilityHidden(true)
        }
        .font(.system(size: 9.5, weight: .medium, design: .rounded))
        .foregroundColor(dark ? Color(red: 0.72, green: 0.80, blue: 0.91) : Color(red: 0.17, green: 0.25, blue: 0.36).opacity(0.75))
        .frame(width: QuotaLayout.body.width, height: QuotaLayout.body.height)
        .clipShape(WaistedCapsule())
        .overlay(WaistedCapsule().inset(by: 0.4).stroke(LinearGradient(colors: [.white.opacity(dark ? 0.28 : 0.72), .white.opacity(dark ? 0.08 : 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .shadow(color: .black.opacity(dark ? 0.30 : 0.14), radius: 5, x: 0, y: 3)
        .padding(8)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func ring(_ name: String, window: QuotaWindow?, color: Color) -> some View {
        let fresh = model.snapshot?.isFresh(at: model.now) == true && model.error == nil
        let percent = fresh ? window?.remaining(at: model.now) : nil
        let mirror: CGFloat = name == "5H" ? -1 : 1
        return ZStack {
            // The shared base joins the disks through the middle. Only the
            // white track and the quota progress use the open C shape.
            Circle().trim(from: 0, to: QuotaLayout.arcFraction)
                .stroke(Color.white.opacity(dark ? 0.24 : 0.90), style: StrokeStyle(lineWidth: QuotaLayout.stroke, lineCap: .round))
                .rotationEffect(.degrees(QuotaLayout.arcStartDegrees))
                .scaleEffect(x: mirror, y: 1)
            if let percent, percent > 0 {
                let length = QuotaLayout.arcFraction * CGFloat(percent) / 100
                // Keep the upper C cap fixed. Only the lower end retreats toward
                // it as quota falls, including when animating through high values.
                Circle()
                    .trim(from: 0, to: length)
                    .stroke(AngularGradient(colors: [color, color.opacity(0.76), color], center: .center), style: StrokeStyle(lineWidth: QuotaLayout.stroke, lineCap: .round))
                    .rotationEffect(.degrees(QuotaLayout.arcStartDegrees))
                    .scaleEffect(x: mirror, y: 1)
                    .shadow(color: color.opacity(0.24), radius: 1.3)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: percent)
            }
            Text(percent.map { "\($0)" } ?? "--")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(dark ? Color(red: 0.94, green: 0.97, blue: 1) : Color(red: 0.04, green: 0.10, blue: 0.17))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: QuotaLayout.ring, height: QuotaLayout.ring)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name == "5H" ? "5 小时" : "周")剩余额度 \(percent.map { "\($0)%" } ?? status)")
    }

    private var status: String {
        if model.loading && model.snapshot == nil { return "读取中" }
        if model.error != nil { return "额度不可用" }
        if let snapshot = model.snapshot, !snapshot.isFresh(at: model.now) { return "等待更新" }
        return "未知，重置时间请在菜单栏查看"
    }
}

private struct WaistedCapsule: InsettableShape {
    var insetAmount: CGFloat = 0
    func inset(by amount: CGFloat) -> WaistedCapsule {
        var shape = self; shape.insetAmount += amount; return shape
    }
    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = rect.height / 2
        let left = rect.minX + radius, right = rect.maxX - radius
        let waist = rect.height * 1.8 / 64
        let k: CGFloat = 0.55228475
        let arc = radius * k
        // Match the shoulder curvature to the circular caps. Mirrored center
        // handles give the waist the same curvature on both sides of its midpoint.
        let capCurvature = 2 * (1 - k) / (3 * radius * k * k)
        let shoulderHandle = sqrt(2 * waist / (3 * capCurvature))
        let centerHandle = (rect.midX - left) * 0.38
        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY + waist), control1: CGPoint(x: left + shoulderHandle, y: rect.minY), control2: CGPoint(x: rect.midX - centerHandle, y: rect.minY + waist))
        path.addCurve(to: CGPoint(x: right, y: rect.minY), control1: CGPoint(x: rect.midX + centerHandle, y: rect.minY + waist), control2: CGPoint(x: right - shoulderHandle, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control1: CGPoint(x: right + arc, y: rect.minY), control2: CGPoint(x: rect.maxX, y: rect.midY - arc))
        path.addCurve(to: CGPoint(x: right, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.midY + arc), control2: CGPoint(x: right + arc, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY - waist), control1: CGPoint(x: right - shoulderHandle, y: rect.maxY), control2: CGPoint(x: rect.midX + centerHandle, y: rect.maxY - waist))
        path.addCurve(to: CGPoint(x: left, y: rect.maxY), control1: CGPoint(x: rect.midX - centerHandle, y: rect.maxY - waist), control2: CGPoint(x: left + shoulderHandle, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.midY), control1: CGPoint(x: left - arc, y: rect.maxY), control2: CGPoint(x: rect.minX, y: rect.midY + arc))
        path.addCurve(to: CGPoint(x: left, y: rect.minY), control1: CGPoint(x: rect.minX, y: rect.midY - arc), control2: CGPoint(x: left - arc, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// A smooth inner base joins the two disks through the C openings, leaving
/// space above and below the bridge for W and 5H. One gradient fills the whole
/// outline so the left and right colors cannot form a hard cut at the seam.
private struct TaijiBaseOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let separation = (QuotaLayout.ring + QuotaLayout.gap) * rect.width / QuotaLayout.body.width
        let radius = QuotaLayout.ring / 2 * rect.height / QuotaLayout.body.height
        let left = CGPoint(x: rect.midX - separation / 2, y: rect.midY)
        let right = CGPoint(x: rect.midX + separation / 2, y: rect.midY)
        let angle = (1 - QuotaLayout.arcFraction) * .pi
        let x = radius * cos(angle), y = radius * sin(angle)
        let leftTop = CGPoint(x: left.x + x, y: left.y - y)
        let rightBottom = CGPoint(x: right.x - x, y: right.y + y)
        let rightTop = CGPoint(x: right.x - x, y: right.y - y)
        let leftBottom = CGPoint(x: left.x + x, y: left.y + y)
        let handle = (rightTop.x - leftTop.x) * 0.34
        let dx = handle * sin(angle), dy = handle * cos(angle)
        var path = Path()
        path.move(to: leftTop)
        path.addArc(center: left, radius: radius, startAngle: .radians(-Double(angle)), endAngle: .radians(Double(angle)), clockwise: true)
        path.addCurve(to: rightBottom,
                      control1: CGPoint(x: leftBottom.x + dx, y: leftBottom.y - dy),
                      control2: CGPoint(x: rightBottom.x - dx, y: rightBottom.y - dy))
        path.addArc(center: right, radius: radius, startAngle: .radians(Double(.pi - angle)), endAngle: .radians(Double(.pi + angle)), clockwise: true)
        path.addCurve(to: leftTop,
                      control1: CGPoint(x: rightTop.x - dx, y: rightTop.y + dy),
                      control2: CGPoint(x: leftTop.x + dx, y: leftTop.y + dy))
        path.closeSubpath()
        return path
    }
}

/// Keep the complete reference S and its horizontal shoulder handles. Adjust
/// only its vertical placement so it passes through both C cap centerlines;
/// the natural tails still continue beneath the white tracks.
struct BetweenRingsCurve: Shape {
    private static let firstHandleX: CGFloat = (108.70 - 65) / 78
    private static let secondHandleX: CGFloat = (97.545 - 65) / 78

    private static func x(at t: CGFloat) -> CGFloat {
        let u = 1 - t
        return 3 * u * u * t * firstHandleX + 3 * u * t * t * secondHandleX + t * t * t
    }

    private static func parameter(atX target: CGFloat) -> CGFloat {
        var lower: CGFloat = 0, upper: CGFloat = 1
        for _ in 0..<40 {
            let middle = (lower + upper) / 2
            if x(at: middle) < target { lower = middle } else { upper = middle }
        }
        return (lower + upper) / 2
    }

    private static let verticalOffsets: (bottom: CGFloat, top: CGFloat) = {
        let radius = QuotaLayout.ring / 2
        let angle = (1 - QuotaLayout.arcFraction) * .pi
        let capX = radius * cos(angle) / (QuotaLayout.ring + QuotaLayout.gap)
        let left = parameter(atX: capX), right = parameter(atX: 1 - capX)
        // The reference handles share their respective endpoint heights, so
        // the vertical cubic is a smoothstep between the two natural tails.
        let leftWeight = left * left * (3 - 2 * left)
        let rightWeight = right * right * (3 - 2 * right)
        let capY = radius * sin(angle)
        let height = 2 * capY / (rightWeight - leftWeight)
        let bottom = capY + height * leftWeight
        return (bottom, height - bottom)
    }()

    static var gradientStart: UnitPoint { UnitPoint(x: 0.5, y: 0.5 - verticalOffsets.top / QuotaLayout.body.height) }
    static var gradientEnd: UnitPoint { UnitPoint(x: 0.5, y: 0.5 + verticalOffsets.bottom / QuotaLayout.body.height) }

    func path(in rect: CGRect) -> Path {
        let separation = (QuotaLayout.ring + QuotaLayout.gap) * rect.width / QuotaLayout.body.width
        let left = CGPoint(x: rect.midX - separation / 2, y: rect.midY)
        let bottom = rect.midY + Self.verticalOffsets.bottom * rect.height / QuotaLayout.body.height
        let top = rect.midY - Self.verticalOffsets.top * rect.height / QuotaLayout.body.height
        var path = Path()
        path.move(to: CGPoint(x: left.x, y: bottom))
        path.addCurve(to: CGPoint(x: left.x + separation, y: top),
                      control1: CGPoint(x: left.x + separation * Self.firstHandleX, y: bottom),
                      control2: CGPoint(x: left.x + separation * Self.secondHandleX, y: top))
        return path
    }
}

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    let panel: PassivePanel
    let size = QuotaView.size
    private var wasAbove = false
    init(model: DisplayModel) {
        panel = PassivePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pet's Pet 额度"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: QuotaView(model: model))
    }

    func update(_ state: PetState) -> CGRect? {
        guard let rect = state.rect, let primary = NSScreen.screens.first else { hide(); return nil }
        let anchor = Placement.appKitRect(rect, primaryTop: primary.frame.maxY)
        let occupied = state.occupiedRect.map { Placement.appKitRect($0, primaryTop: primary.frame.maxY) }
        guard let placed = Placement.frame(anchor: anchor, occupied: occupied, size: size, screens: NSScreen.screens.map(\.visibleFrame), wasAbove: wasAbove) else { hide(); return nil }
        wasAbove = placed.minY >= anchor.maxY
        let level = max(NSWindow.Level.floating.rawValue, min(state.layer + 1, NSWindow.Level.statusBar.rawValue))
        if panel.level.rawValue != level { panel.level = NSWindow.Level(rawValue: level) }
        if panel.frame.origin != placed.origin { panel.setFrameOrigin(placed.origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        return placed
    }
    func hide() { panel.orderOut(nil); wasAbove = false }
}
