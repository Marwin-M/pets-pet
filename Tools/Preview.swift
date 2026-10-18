import AppKit
import SwiftUI
import ImageIO
import PetsPetCore

/// Visual-review fixtures only. This program never launches, signs, or installs PetsPet.app.
@main
struct PreviewRenderer {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: "Previews/Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let sampleCards = try JSONDecoder().decode(ResetCreditsSummary.self, from: JSONSerialization.data(withJSONObject: [
            "availableCount": 2,
            "credits": [
                ["resetType": "codexRateLimits", "status": "available", "expiresAt": now.addingTimeInterval(7 * 86400).timeIntervalSince1970],
                ["resetType": "codexRateLimits", "status": "available", "expiresAt": now.addingTimeInterval(14 * 86400).timeIntervalSince1970]
            ]
        ]))
        func model(_ fiveHour: Double?, _ weekly: Double?, planType: String? = nil, days: Double? = nil) -> DisplayModel {
            let value = DisplayModel()
            value.now = now
            value.loading = false
            value.snapshot = QuotaSnapshot(
                fiveHour: fiveHour.map { QuotaWindow(usedPercent: $0, windowDurationMins: 300, resetsAt: now.addingTimeInterval(7200).timeIntervalSince1970) },
                weekly: QuotaWindow(usedPercent: weekly, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(days.map { $0 * 86400 } ?? 200000).timeIntervalSince1970), fetchedAt: now, resetCredits: sampleCards, planType: planType)
            return value
        }
        if CommandLine.arguments.contains("--position-layout") {
            let sample = model(34, 12)
            for dark in [false, true] {
                let foreground = dark ? Color(white: 0.88) : Color(white: 0.22)
                let muted = dark ? Color(white: 0.58) : Color(white: 0.48)
                let surface = dark ? Color(red: 0.13, green: 0.15, blue: 0.18) : Color(red: 0.91, green: 0.94, blue: 0.95)
                let illustration = VStack(alignment: .leading, spacing: 16) {
                    Text("侧栏底部 · 半透明悬浮").font(.system(size: 19, weight: .semibold))
                    HStack(spacing: 0) {
                        VStack {
                            Spacer()
                            Text("M").font(.system(size: 9, weight: .medium)).foregroundStyle(.white)
                                .frame(width: 24, height: 24).background(Color(red: 0.60, green: 0.34, blue: 0.72), in: Circle())
                                .padding(.bottom, 12)
                        }.frame(width: 44)
                        ZStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("最近对话").font(.system(size: 11)).foregroundStyle(muted).frame(height: 32)
                                ForEach(1...9, id: \.self) { index in
                                    Text("产品讨论与开发记录 \(String(format: "%02d", index))")
                                        .font(.system(size: 13)).frame(height: 32, alignment: .leading)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                            QuotaView(model: sample).opacity(0.78).padding(.bottom, 4)
                        }.frame(width: 264)
                    }.frame(height: 330).background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("组件底边与左侧头像对齐\n列表保留滚动留白，最后一条聊天可滑到组件上方")
                        .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
                    Text("布局示意 · 复用原生组件 · 额度 66 / 88 为演示数值")
                        .font(.system(size: 9)).foregroundStyle(muted)
                }.foregroundStyle(foreground).padding(20).frame(width: 348)
                    .background(dark ? Color(white: 0.09) : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                try write(illustration, to: output.appendingPathComponent(dark ? "position-layout-dark.png" : "position-layout.png"))
            }
            print("Updated static position illustrations using the native component; no live-client or browser capture.")
            return
        }
        if CommandLine.arguments.contains("--position") {
            let loading = DisplayModel(); loading.now = now
            let failure = DisplayModel(); failure.now = now; failure.loading = false; failure.error = "预览：查询失败"
            let cases = [("current", model(34, 12)), ("pro", model(nil, 12, planType: "pro", days: 1.2)),
                         ("loading", loading), ("error", failure)]
            for (name, value) in cases {
                guard let payload = SidebarQuotaRenderer().payload(for: value) else { throw CocoaError(.fileWriteUnknown) }
                for appearance in ["light", "dark"] {
                    guard let source = payload[appearance] as? String, source.count <= 128000,
                          let data = Data(base64Encoded: String(source.dropFirst(22))) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: output.appendingPathComponent("position-\(name)\(appearance == "dark" ? "-dark" : "").png"), options: .atomic)
                }
            }
            print("Updated position samples through the production 2× sidebar renderer; app bundle unchanged.")
            return
        }
        if CommandLine.arguments.contains("--menu") {
            let calendar = Calendar(identifier: .gregorian)
            let start = calendar.startOfDay(for: now)
            let usage = DailyTokenUsageSnapshot(dayStart: start, dayEnd: calendar.date(byAdding: .day, value: 1, to: start)!, timeZoneIdentifier: calendar.timeZone.identifier, input: 1200000, cached: 1100000, output: 34567, isComplete: true, fetchedAt: now)!
            let time = DateFormatter(); time.timeStyle = .medium
            let sample: [String: Any] = [
                "sample": true,
                "rows": QuotaMenu.rows(snapshot: model(34, 12).snapshot, dailyUsage: usage, at: now),
                "updated": "数据更新于：\(time.string(from: now))",
                "dailyTip": DailyTokenUsageMenu(snapshot: usage, at: now).toolTip
            ]
            try JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("menu-layout.json"), options: .atomic)
            let info = try Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist"))
            let version = (try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String ?? ""
            let rows = sample["rows"] as? [String] ?? []
            // A compact menu-layout illustration, using the same real row formatter.
            // This is review artwork, not a screenshot of a running application.
            for dark in [false, true] {
                let infoColor = dark ? Color(white: 0.96) : Color(white: 0.11)
                let metadataColor = dark ? Color(white: 0.85) : Color(white: 0.27)
                try write(VStack(alignment: .leading, spacing: 8) {
                    Text("Pet’s Pet · \(version)").foregroundStyle(metadataColor)
                    Text("正在跟随宠物").foregroundStyle(metadataColor)
                    Divider()
                    ForEach(rows, id: \.self) { Text($0).foregroundStyle(infoColor) }
                    Text(sample["updated"] as? String ?? "").foregroundStyle(metadataColor)
                    Text("立即刷新")
                    Divider()
                    ForEach(["显示设置", "侧栏连接（已连接）", "工具与诊断"], id: \.self) { title in
                        HStack { Text(title); Spacer(); Image(systemName: "chevron.right") }
                    }
                    Divider()
                    Text("退出 Pet’s Pet")
                }.font(.system(size: 13)).foregroundStyle(dark ? Color(white: 0.9) : Color(red: 0.15, green: 0.17, blue: 0.2))
                    .padding(14).frame(width: 340, alignment: .leading)
                    .background(dark ? Color(white: 0.17) : Color(red: 0.92, green: 0.93, blue: 0.94))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .clipShape(RoundedRectangle(cornerRadius: 12)),
                    to: output.appendingPathComponent(dark ? "menu-dark.png" : "menu.png"))
            }
            print("Updated menu review sample; app bundle unchanged.")
            return
        }
        if CommandLine.arguments.contains("--pro") {
            let error = model(nil, 12, planType: "pro", days: 1.2)
            error.error = "预览：查询失败"
            let stale = model(nil, 12, planType: "pro", days: 1.2)
            stale.now = now.addingTimeInterval(151)
            let missing = DisplayModel(); missing.now = now; missing.loading = false
            missing.snapshot = QuotaSnapshot(fiveHour: nil, weekly: QuotaWindow(usedPercent: 12, windowDurationMins: 10080, resetsAt: nil), fetchedAt: now, planType: "pro")
            let forcedQuota = model(nil, 12, planType: "pro", days: 1.2)
            forcedQuota.contentMode = .quota
            let plusCountdown = model(34, 12, planType: "plus", days: 1.2)
            plusCountdown.contentMode = .countdown
            let cases = [
                ("pro", model(nil, 12, planType: "pro", days: 1.2)),
                ("pro-half", model(nil, 12, planType: "pro", days: 3.5)),
                ("pro-start", model(nil, 0, planType: "pro", days: 7)),
                ("pro-soon", model(nil, 100, planType: "pro", days: 0.01)),
                ("pro-expired", model(nil, 12, planType: "pro", days: 0)),
                ("pro-error", error), ("pro-stale", stale), ("pro-missing", missing),
                ("pro-forced-quota", forcedQuota),
                ("pro-with-5h", model(34, 12, planType: "pro")),
                ("plus-countdown", plusCountdown)
            ]
            for (name, value) in cases {
                for appearance in [AppearancePreference.light, .dark] {
                    value.appearance = appearance
                    try write(QuotaView(model: value), to: output.appendingPathComponent("\(name)\(appearance == .dark ? "-dark" : "").png"))
                }
            }
            print("Updated Pro native review images; app bundle unchanged.")
            return
        }
        // Public demonstration images always show 66 / 88 remaining.
        let current = model(34, 12)
        let limits = model(0, 100)
        let loading = DisplayModel(); loading.now = now
        let failure = DisplayModel(); failure.now = now; failure.loading = false; failure.error = "预览：查询失败"
        let stale = model(34, 12)
        stale.snapshot = QuotaSnapshot(fiveHour: stale.snapshot?.fiveHour, weekly: stale.snapshot?.weekly, fetchedAt: now.addingTimeInterval(-300))
        var cases = [("current", current), ("limits", limits), ("loading", loading), ("error", failure), ("stale", stale)]
        for remaining in [100, 75, 50, 25, 0] {
            cases.append(("progress-\(remaining)", model(Double(100 - remaining), Double(100 - remaining))))
        }
        for (name, value) in cases {
            for appearance in [AppearancePreference.light, .dark] {
                value.appearance = appearance
                let suffix = appearance == .dark ? "-dark" : ""
                try write(QuotaView(model: value), to: output.appendingPathComponent("\(name)\(suffix).png"))
            }
        }
        let menu: [String: Any] = ["sample": true, "rows": QuotaMenu.rows(snapshot: current.snapshot, at: now)]
        try JSONSerialization.data(withJSONObject: menu, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("menu-preview.json"), options: .atomic)
        let referenceWidth = try writeCurveAudit(to: output)
        let metadata: [String: Any] = ["width": QuotaView.size.width, "height": QuotaView.size.height, "referenceWidth": referenceWidth, "generatedAt": ISO8601DateFormatter().string(from: now)]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("layout.json"), options: .atomic)
        print("Updated SwiftUI browser previews; app bundle unchanged.")
    }

    @MainActor private static func write<Content: View>(_ content: Content, to url: URL) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Overlay the actual native path on the unmodified reference, in the same
    /// circle coordinate system. Cyan samples mark the visible reference seam.
    @MainActor private static func writeCurveAudit(to output: URL) throws -> CGFloat {
        let body = CGRect(x: 0, y: 0, width: QuotaView.size.width - 16, height: QuotaView.size.height - 16)
        var points: [CGPoint] = []
        BetweenRingsCurve().path(in: body).cgPath.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: points.append(element.points[0])
            case .addCurveToPoint: points.append(contentsOf: (0..<3).map { element.points[$0] })
            default: break
            }
        }
        guard points.count >= 4, (points.count - 1).isMultiple(of: 3) else { throw CocoaError(.fileWriteUnknown) }
        // Align by circle centers, and undo the requested vertical mirror only
        // in this audit so curvature can be compared with the original photo.
        let separation = QuotaLayout.ring + QuotaLayout.gap
        let scale = 78 / separation
        let leftCenterX = body.midX - separation / 2
        let mapped = points.map { CGPoint(x: 65 + ($0.x - leftCenterX) * scale, y: 47 - ($0.y - body.midY) * scale) }
        let segments = stride(from: 0, to: mapped.count - 1, by: 3).map { Array(mapped[$0...($0 + 3)]) }
        func at(_ t: CGFloat, on segment: [CGPoint]) -> CGPoint {
            let u = 1 - t
            let weights = [u*u*u, 3*u*u*t, 3*u*t*t, t*t*t]
            return zip(segment, weights).reduce(CGPoint.zero) { result, item in
                CGPoint(x: result.x + item.0.x * item.1, y: result.y + item.0.y * item.1)
            }
        }
        // Check the actual native path against the track's rendered end
        // angles, independently of the shape's endpoint fitting calculation.
        var attachmentErrors: [Double] = []
        for bounds in [body, CGRect(x: 0, y: 0, width: 256, height: 128), CGRect(x: 9, y: 7, width: 192, height: 96)] {
            var native: [CGPoint] = []
            BetweenRingsCurve().path(in: bounds).cgPath.applyWithBlock { pointer in
                let element = pointer.pointee
                if element.type == .moveToPoint { native.append(element.points[0]) }
                if element.type == .addCurveToPoint { native.append(contentsOf: (0..<3).map { element.points[$0] }) }
            }
            guard native.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
            let sx = bounds.width / QuotaLayout.body.width, sy = bounds.height / QuotaLayout.body.height
            let halfSeparation = (QuotaLayout.ring + QuotaLayout.gap) * sx / 2
            let radiusX = QuotaLayout.ring * sx / 2, radiusY = QuotaLayout.ring * sy / 2
            let lowerAngle = (QuotaLayout.arcStartDegrees + Double(QuotaLayout.arcFraction) * 360) * .pi / 180
            let upperAngle = QuotaLayout.arcStartDegrees * .pi / 180
            let caps = [
                CGPoint(x: bounds.midX - halfSeparation - radiusX * cos(lowerAngle), y: bounds.midY + radiusY * sin(lowerAngle)),
                CGPoint(x: bounds.midX + halfSeparation + radiusX * cos(upperAngle), y: bounds.midY + radiusY * sin(upperAngle))
            ]
            for cap in caps {
                var lower: CGFloat = 0, upper: CGFloat = 1
                for _ in 0..<45 {
                    let middle = (lower + upper) / 2
                    if at(middle, on: native).x < cap.x { lower = middle } else { upper = middle }
                }
                let actual = at((lower + upper) / 2, on: native)
                let error = hypot(actual.x - cap.x, actual.y - cap.y)
                guard error < 0.001 else { throw CocoaError(.fileReadCorruptFile) }
                attachmentErrors.append(Double(error))
            }
            // Preserve the full-width shoulders and horizontal natural ends.
            guard abs(native[0].x - (bounds.midX - halfSeparation)) < 0.001,
                  abs(native[3].x - (bounds.midX + halfSeparation)) < 0.001,
                  abs(native[1].y - native[0].y) < 0.001,
                  abs(native[2].y - native[3].y) < 0.001 else { throw CocoaError(.fileReadCorruptFile) }
            for index in 1...100 {
                let previous = at(CGFloat(index - 1) / 100, on: native)
                let next = at(CGFloat(index) / 100, on: native)
                guard next.x > previous.x, next.y < previous.y else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        try JSONSerialization.data(withJSONObject: ["capCenterErrors": attachmentErrors, "fullShouldersPreserved": true, "monotonic": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("curve-attachment-checks.json"), options: .atomic)
        print(String(format: "Cap center alignment: max %.8f pt across %d attachments; full shoulders and monotonic S checked.", attachmentErrors.max() ?? 0, attachmentErrors.count))
        let trace: [(CGFloat, CGFloat)] = [(92,31),(94,34),(97,37),(99,40),(101,43),(103,46),(105,49),(106,52),(108,55),(111,58)]
        let errors = try trace.map { x, y -> CGFloat in
            guard let segment = segments.first(where: { y >= $0[0].y && y <= $0[3].y }) else { throw CocoaError(.fileWriteUnknown) }
            var lower: CGFloat = 0, upper: CGFloat = 1
            for _ in 0..<40 {
                let middle = (lower + upper) / 2
                if at(middle, on: segment).y < y { lower = middle } else { upper = middle }
            }
            return at((lower + upper) / 2, on: segment).x - x
        }
        let rms = sqrt(errors.reduce(0) { $0 + $1*$1 } / CGFloat(errors.count))
        let path = "M \(mapped[0].x) \(mapped[0].y) " + segments.map { "C \($0[1].x) \($0[1].y) \($0[2].x) \($0[2].y) \($0[3].x) \($0[3].y)" }.joined(separator: " ")
        let reference = try Data(contentsOf: output.appendingPathComponent("reference.png")).base64EncodedString()
        let dots = trace.map { "<circle cx='\($0.0)' cy='\($0.1)' r='0.65' fill='#3fffe5'/>" }.joined()
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="860" height="260" viewBox="0 0 430 130">
        <rect width="430" height="130" fill="#f5f6f8"/>
        <g font-family="system-ui,sans-serif" font-size="8" fill="#334455"><text x="5" y="12">原参考图</text><text x="225" y="12">当前曲线翻回原方向叠加：橙线；取点：青点</text></g>
        <image x="5" y="20" width="205" height="93" href="data:image/png;base64,\(reference)"/>
        <g transform="translate(225,20)"><image width="205" height="93" href="data:image/png;base64,\(reference)"/><path d="\(path)" stroke="#ffb45b" stroke-width="0.6" fill="none"/>\(dots)</g>
        <text x="5" y="125" font-family="system-ui,sans-serif" font-size="7" fill="#687684">端部已调整至轨道中心；旧参考仅用于走势对照，非逐像素目标。中段采样差异 \(String(format: "%.2f", Double(rms))) 像素。</text>
        </svg>
        """
        try svg.write(to: output.appendingPathComponent("curve-audit.svg"), atomically: true, encoding: .utf8)
        print(String(format: "Reference seam audit: %.2f px RMS across %d visible samples.", Double(rms), trace.count))
        return 205 / scale
    }
}
