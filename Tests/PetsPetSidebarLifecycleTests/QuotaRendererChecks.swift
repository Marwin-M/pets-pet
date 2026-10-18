import AppKit
import PetsPetCore

@main struct QuotaRendererChecks {
    @MainActor static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw NSError(domain: "QuotaRendererChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let model = DisplayModel(), renderer = SidebarQuotaRenderer()
        let now = Date(timeIntervalSince1970: 1800000000)
        model.now = now
        func snapshot(five: Bool = true, pro: Bool = false) -> QuotaSnapshot {
            QuotaSnapshot(fiveHour: five ? QuotaWindow(usedPercent: 34, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970) : nil,
                          weekly: QuotaWindow(usedPercent: 12, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(3 * 86400).timeIntervalSince1970),
                          fetchedAt: now, planType: pro ? "pro" : "plus")
        }
        func image(_ payload: [String: Any], _ key: String) throws -> NSBitmapImageRep {
            let source = payload[key] as! String
            try check(source.hasPrefix("data:image/png;base64,"), "native payload is a local PNG")
            let bytes = Data(base64Encoded: String(source.dropFirst(22)))!
            let bitmap = NSBitmapImageRep(data: bytes)!
            try check(bitmap.pixelsWide == 288 && bitmap.pixelsHigh == 160, "native size is 144×80 at 2×")
            return bitmap
        }
        let loading = renderer.payload(for: model)!
        try check((loading["label"] as! String).contains("读取中"), "loading does not invent zero")
        model.loading = false; model.snapshot = snapshot()
        let ready = renderer.payload(for: model)!
        try check((ready["label"] as! String).contains("66%") && (ready["label"] as! String).contains("88%"), "quota and native label agree")
        let light = try image(ready, "light"), dark = try image(ready, "dark")
        try check(ready["light"] as! String != ready["dark"] as! String, "system mode supplies both appearances")
        try check(light.colorAt(x: 0, y: 0)!.alphaComponent == 0 && dark.colorAt(x: 0, y: 0)!.alphaComponent == 0, "outer alignment padding stays transparent")
        try check(renderer.payload(for: model)!["light"] as! String == ready["light"] as! String, "unchanged content reuses native image")
        model.appearance = .light
        let forcedLight = renderer.payload(for: model)!
        try check(forcedLight["light"] as! String == forcedLight["dark"] as! String, "explicit light overrides page theme")
        model.appearance = .dark
        let forcedDark = renderer.payload(for: model)!
        try check(forcedDark["light"] as! String == forcedDark["dark"] as! String, "explicit dark overrides page theme")
        model.appearance = .system; model.snapshot = snapshot(five: false, pro: true)
        let countdown = renderer.payload(for: model)!
        try check((countdown["label"] as! String).contains("3.0 天"), "weekly-only account uses countdown")
        try check(countdown["light"] as! String != ready["light"] as! String, "content and Pro watermark render anew")
        model.contentMode = .quota
        try check(!(renderer.payload(for: model)!["label"] as! String).contains("66%"), "missing 5H never reuses previous account's quota")
        model.error = "offline"
        let error = renderer.payload(for: model)!
        try check((error["label"] as! String).contains("额度不可用"), "query failure is represented")
        model.error = nil; model.snapshot = snapshot(); model.now = now.addingTimeInterval(151)
        let stale = renderer.payload(for: model)!
        try check(!(stale["label"] as! String).contains("66%") && !(stale["label"] as! String).contains("88%"), "stale values are not displayed")
        if CommandLine.arguments.contains("--images") {
            for (name, value) in [("light", ready), ("dark", ready), ("loading", loading), ("error", error), ("countdown", countdown)] {
                let key = name == "dark" ? "dark" : "light"
                let source = value[key] as! String
                try Data(base64Encoded: String(source.dropFirst(22)))!.write(to: URL(fileURLWithPath: ".build/position-quota-\(name).png"))
            }
        }
        print("Sidebar quota renderer checks passed: \(assertions) assertions (real native component; no app launch or installation).")
    }
}
