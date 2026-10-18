import AppKit
import SwiftUI
import PetsPetCore

/// The sidebar uses the same native component as the floating panel. Only the
/// presentation is transferred; quota values never come from the page.
@MainActor final class SidebarQuotaRenderer {
    private var cachedKey = ""
    private var cached: [String: Any]?

    func payload(for model: DisplayModel) -> [String: Any]? {
        let fresh = model.error == nil && model.snapshot?.isFresh(at: model.now) == true
        let mode = model.contentMode.resolved(for: model.snapshot)
        let left = mode == .countdown
            ? (model.error == nil ? model.snapshot?.countdown(at: model.now)?.daysText : nil).map { "\($0) 天" }
            : (fresh ? model.snapshot?.fiveHour?.remaining(at: model.now) : nil).map { "\($0)%" }
        let right = (fresh ? model.snapshot?.weekly?.remaining(at: model.now) : nil).map { "\($0)%" }
        let status = model.loading && model.snapshot == nil ? "读取中" : model.error != nil ? "额度不可用" : "等待更新"
        let label = "\(mode == .countdown ? "距周额度重置" : "5 小时剩余额度")：\(left ?? status)，周剩余额度：\(right ?? status)"
        let key = "\(label)|\(model.appearance.rawValue)|\(model.snapshot?.isPro == true)|\(Int(model.now.timeIntervalSince1970 / 60))|\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)"
        if key == cachedKey, let cached { return cached }
        func image(_ scheme: ColorScheme) -> String? {
            let renderer = ImageRenderer(content: QuotaView(model: model).environment(\.colorScheme, scheme)
                .transaction { $0.disablesAnimations = true })
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
            return "data:image/png;base64," + png.base64EncodedString()
        }
        guard let light = image(.light), let dark = image(.dark) else { return nil }
        let result: [String: Any] = ["light": light, "dark": dark, "appearance": model.appearance.rawValue,
                                   "label": label, "width": QuotaView.size.width, "height": QuotaView.size.height]
        cachedKey = key; cached = result
        return result
    }
}
