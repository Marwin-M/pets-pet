import Foundation
import Darwin
import CoreGraphics
import PetsPetCore

// Command Line Tools do not ship XCTest. Keep the actual behavior checks runnable without Xcode or dependencies.
private var failures = 0
private var assertions = 0
private func fail(_ message: String, file: StaticString, line: UInt) { failures += 1; print("FAIL \(file):\(line): \(message)") }
private func expectTrue(_ expression: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1; if !expression() { fail("expected true", file: file, line: line) }
}
private func expectFalse(_ expression: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1; if expression() { fail("expected false", file: file, line: line) }
}
private func expectEqual<T: Equatable>(_ left: T, _ right: T, file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1; if left != right { fail("\(left) != \(right)", file: file, line: line) }
}
private func expectNil<T>(_ expression: T?, file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1; if expression != nil { fail("expected nil", file: file, line: line) }
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1; do { _ = try expression(); fail("expected an error", file: file, line: line) } catch {}
}

final class PetIdentityTests {
    func testPetImageAndNotificationGroup() {
        expectTrue(PetIdentity.matches(role: "AXImage", identifier: "", labels: ["Codey pet"]))
        expectTrue(PetIdentity.matches(role: "AXGroup", identifier: "", labels: ["猫猫 虚拟宠物"]))
        expectTrue(PetIdentity.matches(role: "AXImage", identifier: "avatar-mascot-button", labels: []))
    }
    func testOrdinaryWindowAndSettingsPreviewAreNotPets() {
        expectFalse(PetIdentity.matches(role: "AXWindow", identifier: "", labels: ["Codey pet"]))
        expectFalse(PetIdentity.matches(role: "AXImage", identifier: "", labels: ["Preview of Codey"]))
        expectFalse(PetIdentity.matches(role: "AXButton", identifier: "", labels: ["Show pet"]))
        expectFalse(PetIdentity.matches(role: "AXGroup", identifier: "", labels: ["cat pet preview"]))
    }
}

final class PlacementTests {
    let size = CGSize(width: 144, height: 80)
    let screen = CGRect(x: 0, y: 25, width: 1470, height: 900)
    func testFollowsPetRatherThanMainWindow() {
        let first = Placement.frame(anchor: CGRect(x: 100, y: 200, width: 100, height: 100), size: size, screens: [screen])!
        let second = Placement.frame(anchor: CGRect(x: 420, y: 280, width: 100, height: 100), size: size, screens: [screen])!
        expectEqual(second.minX - first.minX, 320)
        expectEqual(second.minY - first.minY, 80)
    }
    func testAllEdgesAvoidPetAndRemainOnScreen() {
        for x in [0.0, 700, 1370] {
            for y in [25.0, 400, 825] {
                let pet = CGRect(x: x, y: y, width: 100, height: 100)
                let panel = Placement.frame(anchor: pet, size: size, screens: [screen])!
                expectTrue(screen.contains(panel))
                expectFalse(panel.intersects(pet))
            }
        }
    }
    func testNegativeAndUpperDisplays() {
        let cg = CGRect(x: -800, y: -600, width: 120, height: 120)
        let pet = Placement.appKitRect(cg, primaryTop: 956)
        expectEqual(pet, CGRect(x: -800, y: 1436, width: 120, height: 120))
        let secondary = CGRect(x: -1280, y: 956, width: 1280, height: 800)
        let placed = Placement.frame(anchor: pet, size: size, screens: [screen, secondary])!
        expectTrue(secondary.contains(placed))
    }
    func testNoSpaceOrNoScreenHidesPanel() {
        expectNil(Placement.frame(anchor: screen, size: size, screens: [screen]))
        expectNil(Placement.frame(anchor: CGRect(x: 9000, y: 0, width: 100, height: 100), size: size, screens: [screen]))
        expectNil(Placement.frame(anchor: .zero, size: size, screens: []))
    }
}

final class QuotaTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func parse(_ text: String) throws -> QuotaSnapshot { try QuotaParser.parse(Data(text.utf8), at: now) }

    func testWindowsUseDurationRatherThanPosition() throws {
        let result = try parse(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":{"usedPercent":32,"windowDurationMins":300,"resetsAt":1800000000}}}"#)
        expectEqual(result.fiveHour?.remaining(at: now), 68)
        expectEqual(result.weekly?.remaining(at: now), 58)
    }
    func testCodexBucketOverridesLegacyAndOtherBuckets() throws {
        let result = try parse(#"{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":300}},"code_review":{"primary":{"usedPercent":75,"windowDurationMins":300}}}}"#)
        expectEqual(result.fiveHour?.remaining(at: now), 80)
        expectNil(result.weekly)
    }
    func testOtherBucketsNeverPretendToBeCodex() {
        expectThrows(try parse(#"{"rateLimitsByLimitId":{"code_review":{"primary":{"usedPercent":10,"windowDurationMins":300}}}}"#))
        expectThrows(try parse(#"{"rateLimits":{"limitId":"other","primary":{"usedPercent":10,"windowDurationMins":300}}}"#))
        expectThrows(try parse(#"{"rateLimitsByLimitId":{"codex":{"limitId":"other","primary":{"usedPercent":10,"windowDurationMins":300}}}}"#))
    }
    func testMissingValuesAreUnknownRatherThanZero() throws {
        let result = try parse(#"{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":300,"resetsAt":null},"secondary":null}}"#)
        expectNil(result.fiveHour?.remaining(at: now))
        expectNil(result.weekly)
    }
    func testChangedWindowsCannotBeMislabelled() {
        expectThrows(try parse(#"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":4320}}}"#))
    }
    func testMalformedPayloadFailsExplicitly() {
        expectThrows(try parse(#"{"rateLimits":{"primary":{"usedPercent":"68","windowDurationMins":300}}}"#))
        expectThrows(try parse("not-json"))
    }
    func testBoundariesAndResetDoNotInventNewQuota() {
        func window(_ used: Double?, _ reset: Double?) -> QuotaWindow { QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset) }
        expectEqual(window(0, nil).remaining(at: now), 100)
        expectEqual(window(100, nil).remaining(at: now), 0)
        expectEqual(window(150, nil).remaining(at: now), 0)
        expectEqual(window(-5, nil).remaining(at: now), 100)
        expectNil(window(.nan, nil).remaining(at: now))
        expectNil(window(20, now.timeIntervalSince1970).remaining(at: now))
        expectNil(window(20, now.timeIntervalSince1970 - 1).remaining(at: now))
    }
    func testStaleAndFutureCacheAreNotFresh() {
        expectTrue(QuotaSnapshot(fiveHour: nil, weekly: nil, fetchedAt: now).isFresh(at: now))
        expectFalse(QuotaSnapshot(fiveHour: nil, weekly: nil, fetchedAt: now.addingTimeInterval(-151)).isFresh(at: now))
        expectFalse(QuotaSnapshot(fiveHour: nil, weekly: nil, fetchedAt: now.addingTimeInterval(60)).isFresh(at: now))
    }
}

final class Version120Tests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 144, height: 80)
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testBelowAndExpandedContentAvoidance() {
        let pet = CGRect(x: 400, y: 300, width: 100, height: 100)
        let group = CGRect(x: 300, y: 200, width: 300, height: 200)
        let below = Placement.frame(anchor: pet, occupied: group, size: size, screens: [screen])!
        expectEqual(below.midX, pet.midX)
        expectEqual(below.maxY, group.minY - 4)
        expectFalse(below.intersects(group))
        let low = CGRect(x: 300, y: 40, width: 300, height: 360)
        let above = Placement.frame(anchor: pet, occupied: low, size: size, screens: [screen])!
        expectEqual(above.minY, low.maxY + 4)
        expectFalse(above.intersects(low))
        expectNil(Placement.frame(anchor: pet, occupied: screen, size: size, screens: [screen]))
    }

    func testSwitchingHasHysteresisAndRejectsHugeOverlay() {
        let pet = CGRect(x: 400, y: 100, width: 100, height: 100)
        let direct = Placement.frame(anchor: pet, size: size, screens: [screen])!
        let stable = Placement.frame(anchor: pet, size: size, screens: [screen], wasAbove: true)!
        expectTrue(direct.maxY < pet.minY)
        expectTrue(stable.minY > pet.maxY)
        let tallPet = CGRect(x: 400, y: 100, width: 100, height: 695)
        let onlyBelow = Placement.frame(anchor: tallPet, size: size, screens: [screen], wasAbove: true)
        expectTrue(onlyBelow != nil)
        expectTrue(onlyBelow!.maxY < tallPet.minY)
        let toolbar = CGRect(x: 390, y: 210, width: 120, height: 35)
        let card = CGRect(x: 300, y: 270, width: 300, height: 55)
        let occupied = Placement.occupiedBounds(pet: pet, elements: [toolbar, card, screen, CGRect(x: 900, y: 700, width: 50, height: 20)])
        expectTrue(occupied.contains(pet))
        expectTrue(occupied.contains(toolbar))
        expectTrue(occupied.contains(card))
        expectTrue(occupied.width < screen.width)
    }

    func testReconnectAfterRestartAndReadFailures() {
        var recovery = MonitorRecovery()
        recovery.observe(processID: 10)
        expectTrue(recovery.needsConnection)
        recovery.connected(); recovery.succeeded()
        expectFalse(recovery.needsConnection)
        recovery.failed(at: now)
        expectTrue(recovery.needsConnection)
        expectTrue(recovery.retryAt > now)
        for _ in 0..<30 { recovery.failed(at: now) }
        expectEqual(recovery.retryAt.timeIntervalSince(now), 5)
        recovery.observe(processID: 20)
        expectTrue(recovery.needsConnection)
        expectEqual(recovery.failures, 0)
        expectTrue(recovery.retryAt < now)
        recovery.connected(); recovery.succeeded()
        recovery.observe(processID: 20)
        expectFalse(recovery.needsConnection)
    }

    func testSuccessfulRPCWithUnreadyTreeKeepsRetrying() {
        var recovery = MonitorRecovery()
        recovery.observe(processID: 10)
        recovery.connected()
        recovery.inspected(usable: false, at: now)
        expectTrue(recovery.needsConnection)
        expectEqual(recovery.failures, 1)
        recovery.connected()
        recovery.inspected(usable: false, at: now.addingTimeInterval(1))
        expectTrue(recovery.needsConnection)
        expectEqual(recovery.failures, 2)
        recovery.connected()
        recovery.inspected(usable: true, at: now.addingTimeInterval(3))
        expectFalse(recovery.needsConnection)
        expectEqual(recovery.failures, 0)
        recovery.observe(processID: 20)
        expectTrue(recovery.needsConnection)
        recovery.connected()
        recovery.inspected(usable: false, at: now.addingTimeInterval(4))
        expectTrue(recovery.needsConnection)
    }

    func snapshot(_ cards: Any) throws -> QuotaSnapshot {
        let payload: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300]], "rateLimitResetCredits": cards]
        return try QuotaParser.parse(JSONSerialization.data(withJSONObject: payload), at: now)
    }
    func rows(_ cards: Any, at date: Date? = nil) throws -> [String] {
        QuotaMenu.rows(snapshot: try snapshot(cards), at: date ?? now, timeZone: TimeZone(secondsFromGMT: 0)!)
    }
    func card(_ expiry: Any, status: String = "available", type: String = "codexRateLimits") -> [String: Any] {
        ["status": status, "resetType": type, "expiresAt": expiry]
    }

    func testCardCountIsAuthoritativeAndPartialExpiryIsLabelled() throws {
        let display = try rows(["availableCount": 5, "credits": [card(now.timeIntervalSince1970 + 3600)]])
        expectEqual(display[2], "重置卡：5 张")
        expectTrue(display[3].hasPrefix("已知最近到期："))
        let complete = try rows(["availableCount": 2, "credits": [card(now.timeIntervalSince1970 + 7200), card(now.timeIntervalSince1970 + 3600)]])
        expectEqual(complete[3], "最近到期：11/14 23:13")
        let countOnly = try rows(["availableCount": 3, "credits": NSNull()])
        expectEqual(countOnly[2], "重置卡：3 张")
        expectEqual(countOnly[3], "最近到期：未提供")
    }

    func testUnknownCardsAreNeverReportedAsZero() throws {
        expectEqual(try rows(NSNull())[2], "重置卡：暂不可用")
        expectEqual(try rows(["availableCount": 0, "credits": []])[2], "重置卡：0 张")
        expectEqual(try rows(["availableCount": -1])[2], "重置卡：暂不可用")
        let malformed = try snapshot(["availableCount": "3"])
        expectEqual(malformed.fiveHour?.remaining(at: now), 80)
        expectNil(malformed.resetCredits)
        expectEqual(try rows(["availableCount": 3, "credits": ["invalid"]])[2], "重置卡：3 张")
        expectEqual(try rows(["availableCount": 2, "credits": []])[3], "最近到期：未提供")
    }

    func testExpiredAndStaleCardDataRequireRefresh() throws {
        let cards: [String: Any] = ["availableCount": 1, "credits": [card(now.timeIntervalSince1970 + 30)]]
        expectEqual(try rows(cards, at: now.addingTimeInterval(31))[2], "重置卡：等待刷新")
        expectEqual(try rows(cards, at: now.addingTimeInterval(151))[2], "重置卡：等待刷新")
        expectEqual(try rows(["availableCount": 1, "credits": [card(NSNull())]])[3], "最近到期：无到期限制")
        let redeemed: [String: Any] = ["availableCount": 1, "credits": [card(now.timeIntervalSince1970 - 1, status: "redeemed")]]
        expectEqual(try rows(redeemed)[3], "最近到期：未提供")
        expectEqual(try rows(["availableCount": 1, "credits": [card(NSNull(), type: "unknown")]])[3], "最近到期：未提供")
    }

    func testAppearanceFallback() {
        expectEqual(AppearancePreference(savedValue: nil), .system)
        expectEqual(AppearancePreference(savedValue: "obsolete"), .system)
        expectEqual(AppearancePreference(savedValue: "dark"), .dark)
    }
}

final class Version122Tests {
    func testVisibleQuotaGapMatchesToolbarCardSpacing() {
        // Pet-relative AX geometry from the expanded layout: toolbar ends at
        // 167 pt, task card starts at 179 pt. QuotaView has an 8 pt clear edge.
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 900)
        let pet = Placement.appKitRect(CGRect(x: 400, y: 100, width: 113, height: 123), primaryTop: 900)
        let toolbar = Placement.appKitRect(CGRect(x: 291, y: 227, width: 330, height: 40), primaryTop: 900)
        let card = Placement.appKitRect(CGRect(x: 292, y: 279, width: 330, height: 56), primaryTop: 900)
        let occupied = Placement.occupiedBounds(pet: pet, elements: [pet, toolbar, card])
        let panel = Placement.frame(anchor: pet, occupied: occupied, size: CGSize(width: 144, height: 80), screens: [screen])!
        let visibleGap = card.minY - (panel.maxY - 8)
        expectEqual(visibleGap, toolbar.minY - card.maxY)
        expectEqual(visibleGap, 12)
        expectEqual(occupied.minY, card.minY)
        let restricted = CGRect(x: 0, y: card.minY - 20, width: 1000, height: 900 - card.minY + 20)
        let above = Placement.frame(anchor: pet, occupied: occupied, size: CGSize(width: 144, height: 80), screens: [restricted])!
        expectEqual(above.minY + 8 - occupied.maxY, 12)
        expectFalse(above.intersects(occupied))
    }

    func testRetainedLayoutHeightDoesNotCreateCollapsedGap() {
        let pet = CGRect(x: 200, y: 100, width: 100, height: 100)
        let handle = CGRect(x: 238, y: 211, width: 24, height: 6)
        let wrapper = CGRect(x: 75, y: 80, width: 350, height: 350)
        guard let clipped = Placement.contentBounds(container: wrapper, contents: [pet, handle]) else {
            expectTrue(false); return
        }
        expectEqual(clipped.maxY, handle.maxY + 10)
        let occupied = Placement.occupiedBounds(pet: pet, elements: [clipped, pet, handle])
        expectTrue(occupied.maxY - handle.maxY <= 20)
        expectNil(Placement.contentBounds(container: wrapper, contents: []))
        expectNil(Placement.contentBounds(container: wrapper, contents: [CGRect(x: 900, y: 900, width: 20, height: 20)]))
    }

    func testVisibleCardPaddingSurvivesWrapperClipping() {
        for y: CGFloat in [40, 300] {
            let card = CGRect(x: 80, y: y, width: 330, height: 56)
            let text = card.insetBy(dx: 16, dy: 8)
            expectEqual(Placement.contentBounds(container: card, contents: [text]), card)
            let retained = CGRect(x: 80, y: y - 90, width: 330, height: 236)
            guard let trimmed = Placement.contentBounds(container: retained, contents: [card]) else {
                expectTrue(false); continue
            }
            expectEqual(trimmed.minY, card.minY - 10)
            expectEqual(trimmed.maxY, card.maxY + 10)
            expectTrue(trimmed.contains(card))
        }
    }

    func testFullCardBoundsAboveAndBelowPet() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 900)
        let size = CGSize(width: 144, height: 80)
        let cases: [(CGRect, CGRect, CGRect)] = [
            // Logical geometry based on the two user-provided screenshots.
            (CGRect(x: 183, y: 55, width: 98, height: 100), CGRect(x: 172, y: 165, width: 120, height: 39), CGRect(x: 67, y: 216, width: 330, height: 56)),
            (CGRect(x: 167, y: 176, width: 82, height: 100), CGRect(x: 145, y: 290, width: 120, height: 40), CGRect(x: 41, y: 95, width: 330, height: 56))
        ]
        for (rawPet, rawToolbar, rawCard) in cases {
            let pet = Placement.appKitRect(rawPet, primaryTop: 900)
            let toolbar = Placement.appKitRect(rawToolbar, primaryTop: 900)
            let card = Placement.appKitRect(rawCard, primaryTop: 900)
            let occupied = Placement.occupiedBounds(pet: pet, elements: [pet, toolbar, card, card.insetBy(dx: 20, dy: 12)])
            expectTrue(occupied.contains(card))
            expectTrue(occupied.contains(toolbar))
            let panel = Placement.frame(anchor: pet, occupied: occupied, size: size, screens: [screen])!
            expectFalse(panel.intersects(card))
            expectFalse(panel.intersects(toolbar))
            expectEqual(panel.midX, pet.midX)
            expectTrue(panel.maxY < occupied.minY)
            // With only room above, put the component outside the card too.
            let restricted = CGRect(x: 0, y: occupied.minY - 20, width: 1000, height: 1100 - occupied.minY + 20)
            guard let above = Placement.frame(anchor: pet, occupied: occupied, size: size, screens: [restricted]) else {
                expectTrue(false); continue
            }
            expectTrue(above.minY > occupied.maxY)
            expectFalse(above.intersects(card))
        }
    }

    func testExpandedContainerIsNotDropped() {
        let pet = CGRect(x: 400, y: 500, width: 100, height: 100)
        let expanded = CGRect(x: 300, y: 150, width: 300, height: 310)
        let occupied = Placement.occupiedBounds(pet: pet, elements: [expanded, CGRect(x: 0, y: 0, width: 1800, height: 1200)])
        expectTrue(occupied.contains(expanded))
        expectTrue(occupied.width < 1800)
        expectTrue(occupied.height < 1200)
    }

    func testSlowUIReceivesOnlyNewestPosition() {
        let mailbox = LatestValue<Int>()
        expectTrue(mailbox.offer(0))
        let additionalCallbacks = (1...10_000).reduce(0) { count, position in count + (mailbox.offer(position) ? 1 : 0) }
        expectEqual(additionalCallbacks, 0)
        expectEqual(mailbox.take(), 10_000)
        expectNil(mailbox.take())
        expectTrue(mailbox.offer(10_001))
        expectEqual(mailbox.take(), 10_001)
    }

    func testConcurrentDeliveryDoesNotLoseNewestValue() {
        let mailbox = LatestValue<Int>()
        DispatchQueue.concurrentPerform(iterations: 1000) { mailbox.offer($0) }
        // An update after all concurrent producers must win, even with an
        // already pending UI callback. No consumer replays the old positions.
        expectFalse(mailbox.offer(2000))
        expectEqual(mailbox.take(), 2000)
        expectTrue(mailbox.offer(2001))
        expectEqual(mailbox.take(), 2001)
    }
}

final class PetClickTests {
    let rect = CGRect(x: -150, y: -250, width: 100, height: 100)
    let point = CGPoint(x: -100, y: -200)

    func testClickTogglesOnceAndAllowsSmallReleaseJitter() {
        var gesture = PetClickGesture()
        gesture.begin(at: point, time: 10)
        expectTrue(gesture.end(at: CGPoint(x: -98, y: -199), time: 10.15, petRect: rect))
        expectFalse(gesture.end(at: point, time: 10.2, petRect: rect))
        gesture.begin(at: point, time: 11)
        expectTrue(gesture.end(at: point, time: 11.1, petRect: rect))
    }

    func testDragCannotBecomeClickAfterReturningToStart() {
        var gesture = PetClickGesture()
        gesture.begin(at: point, time: 10)
        expectTrue(gesture.move(to: CGPoint(x: -95, y: -200)))
        expectFalse(gesture.move(to: point))
        expectFalse(gesture.end(at: point, time: 10.1, petRect: rect))
        gesture.begin(at: point, time: 11)
        expectFalse(gesture.end(at: CGPoint(x: -90, y: -200), time: 11.1, petRect: rect))
    }

    func testMouseDragEventsWithinToleranceStillClick() {
        var gesture = PetClickGesture()
        gesture.begin(at: point, time: 10)
        expectFalse(gesture.move(to: CGPoint(x: -98, y: -199)))
        expectFalse(gesture.move(to: CGPoint(x: -96, y: -200)))
        expectTrue(gesture.end(at: CGPoint(x: -99, y: -200), time: 10.2, petRect: rect))
        for _ in 0..<20 {
            gesture.begin(at: point, time: 11)
            expectTrue(gesture.end(at: point, time: 11.1, petRect: rect))
        }
        gesture.begin(at: point, time: 12)
        expectTrue(gesture.move(to: CGPoint(x: CGFloat.nan, y: 0)))
        expectFalse(gesture.end(at: point, time: 12.1, petRect: rect))
    }

    func testClickUsesConfirmedPetWindowAndRejectsOcclusion() {
        let pet = PetClickSurface(processID: 12, windowID: 34, bounds: rect.insetBy(dx: -20, dy: -20))
        func exposed(_ surfaces: [PetClickSurface], at point: CGPoint? = nil) -> Bool {
            PetClickSurface.isPetExposed(at: point ?? self.point, petRect: rect, processID: 12, windowID: 34, surfaces: surfaces)
        }
        expectTrue(exposed([pet]))
        let blocker = PetClickSurface(processID: 99, windowID: 56, bounds: rect)
        expectFalse(exposed([blocker, pet]))
        expectTrue(exposed([pet, blocker]))
        let otherCodexWindow = PetClickSurface(processID: 12, windowID: 57, bounds: rect)
        expectFalse(exposed([otherCodexWindow, pet]))
        let unrelated = PetClickSurface(processID: 99, windowID: 58, bounds: CGRect(x: 0, y: 0, width: 50, height: 50))
        expectTrue(exposed([unrelated, pet]))
        expectFalse(exposed([]))
        expectFalse(exposed([pet], at: CGPoint(x: rect.minX - 1, y: rect.midY)))
        expectFalse(exposed([pet], at: CGPoint(x: CGFloat.nan, y: 0)))
        expectFalse(exposed([PetClickSurface(processID: 99, windowID: 34, bounds: rect)]))
    }

    func testReleaseOutsidePetDoesNotToggle() {
        var gesture = PetClickGesture()
        let edge = CGPoint(x: -51, y: -200)
        gesture.begin(at: edge, time: 10)
        expectFalse(gesture.end(at: CGPoint(x: -49, y: -200), time: 10.1, petRect: rect))
    }

    func testUnmatchedReleaseAndCancelledTargetsDoNotToggle() {
        var gesture = PetClickGesture()
        expectFalse(gesture.end(at: point, time: 10, petRect: rect))
        gesture.begin(at: point, time: 11)
        gesture.cancel() // Pet hidden, permission lost, process changed, or sleep.
        expectFalse(gesture.end(at: point, time: 11.1, petRect: rect))
        gesture.begin(at: point, time: 12)
        expectFalse(gesture.end(at: point, time: 12.1, petRect: .zero))
    }

    func testLongPressAndOutOfOrderEventsDoNotToggle() {
        var gesture = PetClickGesture()
        for releasedAt in [9.9, 11.01] {
            gesture.begin(at: point, time: 10)
            expectFalse(gesture.end(at: point, time: releasedAt, petRect: rect))
        }
        gesture.begin(at: point, time: 20)
        gesture.begin(at: CGPoint(x: -70, y: -200), time: 20.1)
        expectFalse(gesture.end(at: point, time: 20.2, petRect: rect))
    }

    func testInvalidCoordinatesAndTimesDoNotToggle() {
        var gesture = PetClickGesture()
        for bad in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
            gesture.begin(at: bad, time: 10)
            expectFalse(gesture.end(at: point, time: 10.1, petRect: rect))
            gesture.begin(at: point, time: 10)
            expectFalse(gesture.end(at: bad, time: 10.1, petRect: rect))
        }
        gesture.begin(at: point, time: .nan)
        expectFalse(gesture.end(at: point, time: 10, petRect: rect))
        gesture.begin(at: point, time: 10)
        expectFalse(gesture.end(at: point, time: .infinity, petRect: rect))
    }
}

final class TrackingCadenceTests {
    func testIdleNeverStartsFastPollingByItself() {
        let cadence = TrackingCadence()
        for time in [0.0, 1, 10, 10_000] { expectFalse(cadence.isFast(at: time)) }
        expectEqual(TrackingCadence.idleInterval, 1)
        expectEqual(TrackingCadence.frameInterval * 60, 1)
    }

    func testMovementRefreshesBriefFastWindowAndThenExpires() {
        var cadence = TrackingCadence()
        cadence.moved(at: 10)
        expectTrue(cadence.isFast(at: 10))
        expectTrue(cadence.isFast(at: 10.14))
        cadence.moved(at: 10.1)
        expectTrue(cadence.isFast(at: 10.24))
        expectFalse(cadence.isFast(at: 10.26))
        // A held button or missing mouse-up cannot leave a permanent timer.
        expectFalse(cadence.isFast(at: 20))
        cadence.moved(at: 20)
        expectTrue(cadence.isFast(at: 20.01))
    }

    func testReleaseSettlesAndLateEventsCannotShortenWindow() {
        var cadence = TrackingCadence()
        cadence.moved(at: 10)
        cadence.released(at: 10.05)
        cadence.moved(at: 9)
        expectTrue(cadence.isFast(at: 10.24))
        expectFalse(cadence.isFast(at: 10.26))
        cadence.reset()
        cadence.released(at: 20) // Very short drag, coalesced to only a release.
        expectTrue(cadence.isFast(at: 20.19))
        expectFalse(cadence.isFast(at: 20.21))
    }

    func testLifecycleResetStopsFastWork() {
        var cadence = TrackingCadence()
        cadence.moved(at: 10)
        cadence.reset() // Sleep, hidden component, process change, or rescan.
        expectFalse(cadence.isFast(at: 10.01))
        cadence.moved(at: 11)
        expectTrue(cadence.isFast(at: 11))
        cadence.reset()
        expectFalse(cadence.isFast(at: 11))
    }

    func testOneSecondIdleSampleDoesNotFlickerButStaleSamplesExpire() {
        expectTrue(TrackingCadence.isFresh(observedAt: 10, now: 11.02))
        expectTrue(TrackingCadence.isFresh(observedAt: 10, now: 12))
        expectFalse(TrackingCadence.isFresh(observedAt: 10, now: 12.01))
        expectFalse(TrackingCadence.isFresh(observedAt: 10, now: 9.9))
        expectFalse(TrackingCadence.isFresh(observedAt: .nan, now: 10))
        expectFalse(TrackingCadence.isFresh(observedAt: 10, now: .infinity))
    }

    func testInvalidActivityAndBurstInputCannotLatchFastMode() {
        var cadence = TrackingCadence()
        for time in [Double.nan, .infinity, -1] {
            cadence.moved(at: time); cadence.released(at: time)
        }
        expectFalse(cadence.isFast(at: 1))
        for index in 0..<1000 { cadence.moved(at: 10 + Double(index) / 1000) }
        expectTrue(cadence.isFast(at: 11.14))
        expectFalse(cadence.isFast(at: 11.16))
        expectFalse(cadence.isFast(at: .nan))
        expectFalse(cadence.isFast(at: -1))
        let mailbox = LatestValue<Bool>()
        expectTrue(mailbox.offer(false))
        let extraCallbacks = (0..<1000).reduce(0) { count, _ in count + (mailbox.offer(false) ? 1 : 0) }
        expectEqual(extraCallbacks, 0)
        expectFalse(mailbox.offer(true))
        expectEqual(mailbox.take(), true) // Final release wins over old moves.
    }
}

let identity = PetIdentityTests(), placement = PlacementTests(), quotas = QuotaTests(), version120 = Version120Tests(), version122 = Version122Tests(), petClicks = PetClickTests(), cadence = TrackingCadenceTests()
let checks: [(String, () throws -> Void)] = [
    ("idle tracking stays at one second without fast timer", cadence.testIdleNeverStartsFastPollingByItself),
    ("drag activity expires without mouse up and resumes", cadence.testMovementRefreshesBriefFastWindowAndThenExpires),
    ("release settles including coalesced short drags", cadence.testReleaseSettlesAndLateEventsCannotShortenWindow),
    ("lifecycle and visibility reset fast work", cadence.testLifecycleResetStopsFastWork),
    ("one second samples remain valid and stale samples expire", cadence.testOneSecondIdleSampleDoesNotFlickerButStaleSamplesExpire),
    ("invalid events and input bursts cannot latch fast work", cadence.testInvalidActivityAndBurstInputCannotLatchFastMode),
    ("pet click toggles once with release jitter", petClicks.testClickTogglesOnceAndAllowsSmallReleaseJitter),
    ("small mouse drag events still count as clicks", petClicks.testMouseDragEventsWithinToleranceStillClick),
    ("confirmed pet window required and overlapping windows block clicks", petClicks.testClickUsesConfirmedPetWindowAndRejectsOcclusion),
    ("drag and return to origin never toggle", petClicks.testDragCannotBecomeClickAfterReturningToStart),
    ("release outside pet does not toggle", petClicks.testReleaseOutsidePetDoesNotToggle),
    ("unmatched release and cancelled target do not toggle", petClicks.testUnmatchedReleaseAndCancelledTargetsDoNotToggle),
    ("long press and out of order events do not toggle", petClicks.testLongPressAndOutOfOrderEventsDoNotToggle),
    ("invalid click geometry and time rejected", petClicks.testInvalidCoordinatesAndTimesDoNotToggle),
    ("visible quota spacing matches toolbar/card gap", version122.testVisibleQuotaGapMatchesToolbarCardSpacing),
    ("collapsed wrappers discard reserved layout height", version122.testRetainedLayoutHeightDoesNotCreateCollapsedGap),
    ("visible card padding retained above and below", version122.testVisibleCardPaddingSurvivesWrapperClipping),
    ("pet image and notification group", identity.testPetImageAndNotificationGroup),
    ("reject windows and previews", identity.testOrdinaryWindowAndSettingsPreviewAreNotPets),
    ("follow pet coordinates", placement.testFollowsPetRatherThanMainWindow),
    ("all screen edges", placement.testAllEdgesAvoidPetAndRemainOnScreen),
    ("negative and upper displays", placement.testNegativeAndUpperDisplays),
    ("hide when no placement fits", placement.testNoSpaceOrNoScreenHidesPanel),
    ("window duration mapping", quotas.testWindowsUseDurationRatherThanPosition),
    ("explicit Codex bucket", quotas.testCodexBucketOverridesLegacyAndOtherBuckets),
    ("reject unrelated buckets", quotas.testOtherBucketsNeverPretendToBeCodex),
    ("unknown quota fields", quotas.testMissingValuesAreUnknownRatherThanZero),
    ("changed quota durations", quotas.testChangedWindowsCannotBeMislabelled),
    ("invalid payload", quotas.testMalformedPayloadFailsExplicitly),
    ("quota limits and reset expiry", quotas.testBoundariesAndResetDoNotInventNewQuota),
    ("stale and future data", quotas.testStaleAndFutureCacheAreNotFresh),
    ("below pet and outside expanded content", version120.testBelowAndExpandedContentAvoidance),
    ("stable above/below switching and bounded content", version120.testSwitchingHasHysteresisAndRejectsHugeOverlay),
    ("reconnect after process changes and AX failures", version120.testReconnectAfterRestartAndReadFailures),
    ("successful RPC with empty/partial AX tree keeps recovering", version120.testSuccessfulRPCWithUnreadyTreeKeepsRetrying),
    ("reset count and complete/partial expiry details", version120.testCardCountIsAuthoritativeAndPartialExpiryIsLabelled),
    ("missing and malformed reset cards", version120.testUnknownCardsAreNeverReportedAsZero),
    ("expired cards, stale data and unknown statuses", version120.testExpiredAndStaleCardDataRequireRefresh),
    ("saved appearance fallback", version120.testAppearanceFallback),
    ("full task cards above/below pet avoid overlap", version122.testFullCardBoundsAboveAndBelowPet),
    ("expanded card containers retained", version122.testExpandedContainerIsNotDropped),
    ("slow UI drops obsolete position backlog", version122.testSlowUIReceivesOnlyNewestPosition),
    ("concurrent producers retain latest position", version122.testConcurrentDeliveryDoesNotLoseNewestValue)
]
for (name, check) in checks {
    let before = failures
    do { try check() } catch { failures += 1; print("FAIL \(name): \(error)") }
    print("\(failures == before ? "PASS" : "FAIL") \(name)")
}
print("\(checks.count) groups, \(assertions) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
