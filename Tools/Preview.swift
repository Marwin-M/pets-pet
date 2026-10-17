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
        func model(_ fiveHour: Double?, _ weekly: Double?) -> DisplayModel {
            let value = DisplayModel()
            value.now = now
            value.loading = false
            value.snapshot = QuotaSnapshot(
                fiveHour: QuotaWindow(usedPercent: fiveHour, windowDurationMins: 300, resetsAt: now.addingTimeInterval(7200).timeIntervalSince1970),
                weekly: QuotaWindow(usedPercent: weekly, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(200000).timeIntervalSince1970), fetchedAt: now, resetCredits: sampleCards)
            return value
        }
        let current = model(32, 58)
        let limits = model(0, 100)
        let loading = DisplayModel(); loading.now = now
        let failure = DisplayModel(); failure.now = now; failure.loading = false; failure.error = "预览：查询失败"
        let stale = model(32, 58)
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
