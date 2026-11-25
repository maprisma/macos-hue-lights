import XCTest
@testable import HueCore

private let snapshotLine = """
{"phase":"ok","error":"","bridge":{"ip":"192.168.1.50","name":"Hue","model":"BSB002"},"error_code":"","error_args":[],\
"rooms":[{"id":"cccccccc-1111-1111-1111-111111111111","kind":"room","name":"Living room","grouped_light":"bbbbbbbb-1111-1111-1111-111111111111",\
"on":true,"bri":55.0,"on_count":1,"archetype":"living_room","color":"#ffaa00",\
"lights":[{"id":"11111111-1111-1111-1111-111111111111","name":"Ceiling","on":true,"bri":60.0,"dimmable":true,"color":"#ffaa00","reachable":true,"supports_color":true,"supports_ct":true,"mirek":320,"mirek_min":153,"mirek_max":500,"effect":"candle","available_effects":["candle","fire"]},\
{"id":"22222222-2222-2222-2222-222222222222","name":"Arc","on":false,"bri":20.0,"dimmable":true,"color":"#ffd27a","reachable":false}],\
"scenes":[{"id":"dddddddd-1111-1111-1111-111111111111","name":"Relax","active":true}]},\
{"id":"","kind":"other","name":"Other lights","grouped_light":"","on":false,"bri":0,"on_count":0,"archetype":"","color":"#ffd27a",\
"lights":[{"id":"33333333-3333-3333-3333-333333333333","name":"Plug","on":false,"bri":100.0,"dimmable":false,"color":"#ffd27a","reachable":true}],"scenes":[]}],\
"light_count":3,"on_count":1,"candidates":[],"discovering":false,"pair_ip":"","pair_remaining":0}
"""

private func catalogsFromRepo() -> L10n.Catalogs {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return L10n.loadCatalogs(from: root.appendingPathComponent("translations/bundled.json"))
}

final class SnapshotTests: XCTestCase {
    func testParsesSnapshotLineAndExtendedLightFields() throws {
        let s = try XCTUnwrap(HueSnapshot.parse(line: snapshotLine))
        XCTAssertEqual(s.phase, "ok")
        XCTAssertTrue(s.isPaired)
        XCTAssertTrue(s.anyLightOn)
        XCTAssertEqual(s.bridge?.text, "Hue · 192.168.1.50")
        XCTAssertEqual(s.rooms.count, 2)
        XCTAssertEqual(s.rooms[0].lights.map(\.name), ["Ceiling", "Arc"])
        XCTAssertTrue(s.rooms[0].lights[0].supportsColor)
        XCTAssertTrue(s.rooms[0].lights[0].supportsCT)
        XCTAssertEqual(s.rooms[0].lights[0].mirek, 320)
        XCTAssertEqual(s.rooms[0].lights[0].effect, "candle")
        XCTAssertEqual(s.rooms[0].lights[0].availableEffects, ["candle", "fire"])
        XCTAssertEqual(s.rooms[0].unreachableCount, 1)
        XCTAssertEqual(s.rooms[0].scenes.first?.name, "Relax")
        XCTAssertEqual(s.rooms[1].id, "other")
        XCTAssertEqual(s.lightCount, 3)
    }

    func testJunkIsIgnoredOrNeutral() {
        XCTAssertNil(HueSnapshot.parse(line: "not json"))
        XCTAssertNil(HueSnapshot.parse(line: "[1,2]"))
        let s = HueSnapshot.parse(line: #"{"rooms":"x","on_count":"7","bridge":{}}"#)
        XCTAssertEqual(s?.phase, "connecting")
        XCTAssertEqual(s?.onCount, 0)
        XCTAssertNil(s?.bridge)
        XCTAssertEqual(s?.rooms, [])
        XCTAssertFalse(HueSnapshot.initial.anyLightOn)
    }

    func testUnpairedIsNotPaired() {
        XCTAssertFalse(HueSnapshot.parse(line: #"{"phase":"unpaired"}"#)!.isPaired)
        XCTAssertTrue(HueSnapshot.parse(line: #"{"phase":"pairing"}"#)!.isPairing)
    }
}

final class CommandTests: XCTestCase {
    func testLines() {
        XCTAssertEqual(HueCommand.panelOpen.line, #"{"cmd":"panel_open"}"#)
        XCTAssertEqual(HueCommand.panelClosed.line, #"{"cmd":"panel_closed"}"#)
        XCTAssertEqual(HueCommand.pair(ip: "192.168.1.5").line, #"{"cmd":"pair","ip":"192.168.1.5"}"#)
        XCTAssertEqual(HueCommand.light(id: "a", on: true).line, #"{"cmd":"light","id":"a","on":true}"#)
        XCTAssertEqual(HueCommand.group(id: "g", bri: 40).line, #"{"bri":40,"cmd":"group","id":"g"}"#)
        XCTAssertEqual(HueCommand.allOff.line, #"{"cmd":"all_off"}"#)
        XCTAssertEqual(HueCommand.scene(id: "s").line, #"{"cmd":"scene","id":"s"}"#)
    }

    func testRoomUsesGroupElseEachLight() throws {
        let s = try XCTUnwrap(HueSnapshot.parse(line: snapshotLine))
        XCTAssertEqual(HueCommand.room(s.rooms[0], on: false), [.group(id: "bbbbbbbb-1111-1111-1111-111111111111", on: false)])
        XCTAssertEqual(HueCommand.room(s.rooms[1], bri: 30), [.light(id: "33333333-3333-3333-3333-333333333333", bri: 30)])
    }

    func testBrightnessStepAndValidation() {
        XCTAssertEqual(brightnessStep(0), 1)
        XCTAssertEqual(brightnessStep(52), 50)
        XCTAssertEqual(brightnessStep(53), 55)
        XCTAssertEqual(brightnessStep(140), 100)
        XCTAssertEqual(brightnessStep(.nan), 1)
        XCTAssertEqual(cleanedIP("  192.168.1.5 \n"), "192.168.1.5")
        XCTAssertTrue(HueColorMath.validBridgeIP("192.168.1.50"))
        XCTAssertTrue(HueColorMath.validBridgeIP("10.0.0.4"))
        XCTAssertTrue(HueColorMath.validBridgeIP("172.16.5.9"))
        XCTAssertFalse(HueColorMath.validBridgeIP("8.8.8.8"))
        XCTAssertFalse(HueColorMath.validBridgeIP("127.0.0.1"))
    }
}

final class HueModelBuilderTests: XCTestCase {
    func testBuildsRoomsLightsScenesHomeAndSchedules() {
        let lightID = "11111111-1111-1111-1111-111111111111"
        let looseLightID = "11111111-1111-1111-1111-111111111112"
        let deviceID = "22222222-2222-2222-2222-222222222222"
        let roomID = "33333333-3333-3333-3333-333333333333"
        let groupID = "44444444-4444-4444-4444-444444444444"
        let homeGroupID = "55555555-5555-5555-5555-555555555555"
        let sceneID = "66666666-6666-6666-6666-666666666666"
        let schedID = "77777777-7777-7777-7777-777777777777"

        let resources: [[String: Any]] = [
            [
                "id": lightID, "type": "light",
                "owner": ["rid": deviceID, "rtype": "device"],
                "metadata": ["name": "<b>Desk</b> Lamp"],
                "on": ["on": true],
                "dimming": ["brightness": 75.4],
                "color": ["xy": ["x": 0.3127, "y": 0.3290]],
                "color_temperature": ["mirek": 250, "mirek_valid": true, "mirek_schema": ["mirek_minimum": 153, "mirek_maximum": 454]],
                "effects": ["status": "candle", "status_values": ["no_effect", "candle", "fire"]],
            ],
            [
                "id": looseLightID, "type": "light",
                "metadata": ["name": "Hall Plug"],
                "on": ["on": false],
            ],
            [
                "id": deviceID, "type": "device",
                "services": [["rid": lightID, "rtype": "light"]],
            ],
            [
                "id": "88888888-8888-8888-8888-888888888888", "type": "zigbee_connectivity",
                "owner": ["rid": deviceID, "rtype": "device"],
                "status": "connected",
            ],
            [
                "id": groupID, "type": "grouped_light",
                "on": ["on": true], "dimming": ["brightness": 75.0],
            ],
            [
                "id": roomID, "type": "room",
                "metadata": ["name": "Office", "archetype": "office"],
                "children": [["rid": deviceID, "rtype": "device"]],
                "services": [["rid": groupID, "rtype": "grouped_light"]],
            ],
            [
                "id": sceneID, "type": "scene",
                "metadata": ["name": "Focus"],
                "group": ["rid": roomID, "rtype": "room"],
                "status": ["active": "static"],
            ],
            [
                "id": "99999999-9999-9999-9999-999999999999", "type": "bridge_home",
                "services": [["rid": homeGroupID, "rtype": "grouped_light"]],
            ],
            [
                "id": HueModelBuilder.defaultScheduleScriptID, "type": "behavior_script",
                "metadata": ["name": "Timer", "category": "automation"],
            ],
            [
                "id": schedID, "type": "behavior_instance",
                "enabled": true,
                "metadata": ["name": "Morning"],
                "configuration": [
                    "when": [
                        "time_point": ["type": "time", "time": ["hour": 7, "minute": 30]],
                        "recurrence_days": ["monday", "tuesday"],
                    ],
                    "where": [["group": ["rid": roomID, "rtype": "room"]]],
                    "on": ["on": true],
                    "dimming": ["brightness": 80.0],
                    "fade_in_duration": ["seconds": 600],
                ],
            ],
        ]

        let model = HueModelBuilder.build(from: resources)
        XCTAssertEqual(model.lightCount, 2)
        XCTAssertEqual(model.onCount, 1)
        XCTAssertEqual(model.bridgeHomeGroupedLight, homeGroupID)
        XCTAssertEqual(model.scheduleScriptID, HueModelBuilder.defaultScheduleScriptID)
        XCTAssertEqual(model.rooms.count, 2)

        let office = model.rooms[0]
        XCTAssertEqual(office.name, "Office")
        XCTAssertEqual(office.lights.count, 1)
        XCTAssertEqual(office.lights[0].name, "bDesk/b Lamp") // '<' and '>' stripped cleanly
        XCTAssertTrue(office.lights[0].supportsColor)
        XCTAssertTrue(office.lights[0].supportsCT)
        XCTAssertEqual(office.lights[0].mirek, 250)
        XCTAssertEqual(office.lights[0].mirekMax, 454)
        XCTAssertEqual(office.lights[0].effect, "candle")
        XCTAssertEqual(office.lights[0].availableEffects, ["candle", "fire"])
        XCTAssertEqual(office.scenes.first?.active, true)

        XCTAssertEqual(model.rooms[1].kind, "other")
        XCTAssertEqual(model.schedules.count, 1)
        XCTAssertEqual(model.schedules[0].name, "Morning")
        XCTAssertEqual(model.schedules[0].targetName, "Office")
        XCTAssertEqual(model.schedules[0].time, "07:30")
        XCTAssertEqual(model.schedules[0].bri, 80)
        XCTAssertEqual(model.schedules[0].fadeMin, 10)
    }

    func testColorMathConversions() {
        XCTAssertEqual(HueColorMath.clean("<script>Hi & ok</script>\u{07}"), "scriptHi  ok/script")
        XCTAssertTrue(HueColorMath.xyToHex(x: 0.68, y: 0.31).hasPrefix("#"))
        XCTAssertNotNil(HueColorMath.hexToXY("#ff6600"))
        XCTAssertTrue(HueColorMath.mirekToHex(370).hasPrefix("#"))
        XCTAssertEqual(HueColorMath.blendColors(["#000000", "#ffffff"]), "#808080")
        XCTAssertEqual(HueColorMath.blendColors([]), HueColorMath.defaultWarmHex)
    }
}

final class SSEParserTests: XCTestCase {
    func testParsesChunkedCRLFAndMultiLineData() {
        var parser = SSEParser()
        let lightID = "11111111-1111-1111-1111-111111111111"
        let chunk1 = Data(": keepalive\r\nevent: update\r\ndata: [{\"type\":\"update\",\"data\":[".utf8)
        let chunk2 = Data("\r\ndata: {\"id\":\"\(lightID)\",\"type\":\"light\",\"on\":{\"on\":true},\"dimming\":{\"brightness\":42.5}}]}]\r\n\r\n".utf8)

        XCTAssertTrue(parser.feed(chunk1).isEmpty)
        let updates = parser.feed(chunk2)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].resourceType, "light")
        XCTAssertEqual(updates[0].resourceID, lightID)
        XCTAssertEqual(updates[0].on, true)
        XCTAssertEqual(updates[0].brightness, 42.5)
    }

    func testBufferOverflowDropsSafely() {
        var parser = SSEParser(maxBufferBytes: 64)
        let huge = Data(repeating: 0x61, count: 100)
        XCTAssertTrue(parser.feed(huge).isEmpty)
        let lightID = "11111111-1111-1111-1111-111111111111"
        let valid = Data("data: [{\"type\":\"update\",\"data\":[{\"id\":\"\(lightID)\",\"type\":\"light\",\"on\":{\"on\":false}}]}]\n\n".utf8)
        // Payload exceeds 64 bytes -> dropped safely without crashing
        XCTAssertTrue(parser.feed(valid).isEmpty)
    }
}

final class RuleEngineTests: XCTestCase {
    private let a = "11111111-1111-1111-1111-111111111111"
    private let b = "22222222-2222-2222-2222-222222222222"
    private let c = "33333333-3333-3333-3333-333333333333"

    private func makeSnapshot(aOn: Bool = false, bOn: Bool = false) -> HueSnapshot {
        HueSnapshot(
            phase: "ok",
            rooms: [
                HueRoom(
                    hueID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", kind: "room", name: "Office",
                    groupedLight: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", on: aOn || bOn, bri: 80,
                    onCount: (aOn ? 1 : 0) + (bOn ? 1 : 0), archetype: "office", color: "#ffd27a",
                    lights: [
                        HueLight(id: a, name: "A", on: aOn, bri: 80, dimmable: true, color: "#ffd27a"),
                        HueLight(id: b, name: "B", on: bOn, bri: 50, dimmable: true, color: "#ffd27a"),
                    ],
                    scenes: []
                ),
            ],
            lightCount: 2,
            onCount: (aOn ? 1 : 0) + (bOn ? 1 : 0)
        )
    }

    func testFollowMirrorOffMatchBriAndCooldown() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = HueRule(
            id: "r1", name: "A->B", kind: "follow", triggerKind: "light", triggerID: a,
            triggerState: "on", targets: [HueRuleTarget(kind: "light", id: b, action: "on")],
            mirrorOff: true, matchBri: true
        )
        let engine = RuleEngine(rules: [rule], now: { now })
        let snap = makeSnapshot()

        let onActions = engine.evaluateChange(kind: "light", id: a, isOn: true, bri: 72, snapshot: snap)
        XCTAssertEqual(onActions.count, 1)
        XCTAssertEqual(onActions[0].id, b)
        XCTAssertEqual(onActions[0].on, true)
        XCTAssertEqual(onActions[0].bri, 72)

        // Echo suppression for B within 1.5s matches expected state (true),
        // while an opposite external toggle (false) is NOT suppressed.
        XCTAssertTrue(engine.isEcho(kind: "light", id: b, isOn: true))
        XCTAssertFalse(engine.isEcho(kind: "light", id: b, isOn: false))
        // Cooldown prevents re-firing within 2.0s
        now += 1.0
        XCTAssertTrue(engine.evaluateChange(kind: "light", id: a, isOn: false, snapshot: snap).isEmpty)

        // After 2.5s cooldown & echo cleared, mirrorOff triggers OFF on B
        now += 2.0
        let offActions = engine.evaluateChange(kind: "light", id: a, isOn: false, snapshot: snap)
        XCTAssertEqual(offActions.count, 1)
        XCTAssertEqual(offActions[0].on, false)
        XCTAssertTrue(engine.isEcho(kind: "light", id: b, isOn: false))
        XCTAssertFalse(engine.isEcho(kind: "light", id: b, isOn: true))
    }

    func testRoomRuleSuppressesMemberLightEchoes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = makeSnapshot(aOn: true, bOn: true)
        let officeID = snap.rooms[0].id
        let sleepRoomRule = HueRule(
            id: "r-room", name: "Sleep Office", kind: "desktop", triggerKind: "desktop", triggerID: "desktop",
            triggerState: "sleep", targets: [HueRuleTarget(kind: "room", id: officeID, action: "off")]
        )
        let engine = RuleEngine(rules: [sleepRoomRule], now: { now })
        let actions = engine.evaluateDesktopEvent("sleep", snapshot: snap)
        XCTAssertEqual(actions.count, 1)
        XCTAssertTrue(engine.isEcho(kind: "room", id: officeID, isOn: false))
        XCTAssertTrue(engine.isEcho(kind: "light", id: a, isOn: false))
        XCTAssertTrue(engine.isEcho(kind: "light", id: b, isOn: false))
        XCTAssertFalse(engine.isEcho(kind: "light", id: a, isOn: true))
    }

    func testExclusiveAndDesktopAndPauseAndLogCap() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let excl = HueRule(
            id: "r-excl", name: "Exclusive", kind: "exclusive", triggerKind: "light", triggerID: a,
            triggerState: "on", targets: [HueRuleTarget(kind: "light", id: b, action: "off")]
        )
        let desk = HueRule(
            id: "r-desk", name: "Sleep Off", kind: "desktop", triggerKind: "desktop", triggerID: "desktop",
            triggerState: "sleep", targets: [HueRuleTarget(kind: "light", id: a, action: "off")]
        )
        let engine = RuleEngine(rules: [excl, desk], now: { now })

        let actions = engine.evaluateChange(kind: "light", id: a, isOn: true, snapshot: makeSnapshot())
        XCTAssertEqual(actions.first?.on, false)
        XCTAssertEqual(actions.first?.id, b)

        let sleepActions = engine.evaluateDesktopEvent("sleep", snapshot: makeSnapshot(aOn: true))
        XCTAssertEqual(sleepActions.first?.id, a)
        XCTAssertEqual(sleepActions.first?.on, false)

        // Pause blocks everything
        engine.paused = true
        now += 5
        XCTAssertTrue(engine.evaluateDesktopEvent("sleep", snapshot: makeSnapshot(aOn: true)).isEmpty)

        // Log caps at 20 entries
        engine.paused = false
        for _ in 0..<25 {
            now += 5
            _ = engine.evaluateDesktopEvent("sleep", snapshot: makeSnapshot(aOn: true))
        }
        XCTAssertEqual(engine.log.count, 20)
    }

    func testOvernightTimeWindowAndOnlyIfOffAndCycles() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let d23 = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 23, minute: 30))!
        let d02 = cal.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 2, minute: 0))!
        let d12 = cal.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 12, minute: 0))!

        XCTAssertTrue(RuleEngine.isWithinTimeWindow(start: "22:00", end: "06:00", at: d23, calendar: cal))
        XCTAssertTrue(RuleEngine.isWithinTimeWindow(start: "22:00", end: "06:00", at: d02, calendar: cal))
        XCTAssertFalse(RuleEngine.isWithinTimeWindow(start: "22:00", end: "06:00", at: d12, calendar: cal))

        let onlyOffRule = HueRule(
            id: "r-off", name: "OnlyIfOff", kind: "companion", triggerKind: "light", triggerID: a,
            triggerState: "on", targets: [HueRuleTarget(kind: "light", id: b, action: "on")], onlyIfOff: true
        )
        let engine = RuleEngine(rules: [onlyOffRule])
        XCTAssertTrue(engine.evaluateChange(kind: "light", id: a, isOn: true, snapshot: makeSnapshot(aOn: true, bOn: true)).isEmpty)
        XCTAssertEqual(engine.evaluateChange(kind: "light", id: a, isOn: true, snapshot: makeSnapshot(aOn: true, bOn: false)).count, 1)

        // Cycle A -> B -> C -> A
        let r1 = HueRule(id: "1", name: "1", kind: "follow", triggerKind: "light", triggerID: a, targets: [HueRuleTarget(kind: "light", id: b)])
        let r2 = HueRule(id: "2", name: "2", kind: "follow", triggerKind: "light", triggerID: b, targets: [HueRuleTarget(kind: "light", id: c)])
        let r3 = HueRule(id: "3", name: "3", kind: "follow", triggerKind: "light", triggerID: c, targets: [HueRuleTarget(kind: "light", id: a)])
        XCTAssertFalse(RuleEngine.detectCycles([r1, r2, r3]).isEmpty)
        XCTAssertTrue(RuleEngine.detectCycles([r1, r2]).isEmpty)
    }
}

final class LocalSchedulerTests: XCTestCase {
    func testFiresOncePerMinuteAndRespectsWeekdays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        // 2026-01-05 is a Monday
        let monday0730 = cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 7, minute: 30))!
        let tuesday0730 = cal.date(from: DateComponents(year: 2026, month: 1, day: 6, hour: 7, minute: 30))!

        let sched = HueSchedule(
            id: "s1", name: "Workday", enabled: true, targetKind: "room", targetID: "r1",
            targetName: "Office", triggerKind: "time", time: "07:30", days: ["monday"],
            action: "on", bri: 85, source: "local"
        )
        let scheduler = LocalScheduler(calendar: cal)
        XCTAssertEqual(scheduler.dueActions(for: [sched], at: monday0730).count, 1)
        // Same minute bucket -> deduplicated
        XCTAssertTrue(scheduler.dueActions(for: [sched], at: monday0730).isEmpty)
        // Wrong weekday -> does not fire
        XCTAssertTrue(scheduler.dueActions(for: [sched], at: tuesday0730).isEmpty)
    }
}

final class DemoBridgeClientTests: XCTestCase {
    @MainActor
    func testDemoHomeControlsRulesAndSchedules() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let demo = DemoBridgeClient(now: { now })
        var latest = demo.currentSnapshot()
        demo.onSnapshot = { latest = $0 }
        demo.start()

        XCTAssertTrue(latest.isDemo)
        XCTAssertEqual(latest.rooms.count, 4)
        XCTAssertEqual(latest.lightCount, 9)
        XCTAssertEqual(latest.schedules.count, 2)
        XCTAssertEqual(latest.rules.count, 2)

        // Turning Desk Lamp OFF mirrors OFF to Monitor Backlight via built-in demo rule!
        demo.setLight(id: DemoBridgeClient.deskLampID, on: false, bri: nil, mirek: nil, xy: nil, effect: nil)
        XCTAssertEqual(latest.light(DemoBridgeClient.deskLampID)?.on, false)
        XCTAssertEqual(latest.light(DemoBridgeClient.monitorBacklightID)?.on, false)
        XCTAssertFalse(latest.ruleLog.isEmpty)

        // All On with Bedroom excluded keeps Bedroom lights off
        demo.allOff()
        XCTAssertEqual(latest.onCount, 0)
        demo.allOn(excludeRooms: [DemoBridgeClient.bedroomRoomID])
        XCTAssertEqual(latest.room(DemoBridgeClient.bedroomRoomID)?.on, false)
        XCTAssertEqual(latest.room(DemoBridgeClient.livingRoomID)?.on, true)

        // Create / toggle / delete schedule
        demo.createSchedule(HueScheduleDraft(
            name: "Night Off", targetKind: "room", targetID: DemoBridgeClient.hallwayRoomID,
            targetName: "Hallway", triggerKind: "time", time: "23:00", action: "off"
        ))
        XCTAssertEqual(latest.schedules.count, 3)
        let added = latest.schedules.first { $0.name == "Night Off" }!
        demo.toggleSchedule(id: added.id, enabled: false)
        XCTAssertEqual(latest.schedules.first { $0.id == added.id }?.enabled, false)
        demo.deleteSchedule(id: added.id)
        XCTAssertEqual(latest.schedules.count, 2)

        // Desktop sleep rule turns off Office
        now += 5
        demo.setGroup(id: DemoBridgeClient.officeGroupID, on: true, bri: nil, mirek: nil, xy: nil, effect: nil)
        XCTAssertEqual(latest.room(DemoBridgeClient.officeRoomID)?.on, true)
        demo.triggerDesktopEvent("sleep")
        XCTAssertEqual(latest.room(DemoBridgeClient.officeRoomID)?.on, false)
    }
}

final class L10nTests: XCTestCase {
    func testSystemLanguage() {
        XCTAssertEqual(L10n.systemLanguage(["de-DE", "en"]), "de")
        XCTAssertEqual(L10n.systemLanguage(["zz", "pt_BR"]), "pt")
        XCTAssertEqual(L10n.systemLanguage(["ja-JP"]), "en")
        XCTAssertEqual(L10n.systemLanguage([]), "en")
    }

    func testCatalogsAndPlurals() {
        let catalogs = catalogsFromRepo()
        XCTAssertEqual(Set(catalogs.keys), Set(L10n.languages.map(\.code)))
        let de = L10n(catalogs: catalogs, setting: "de")
        XCTAssertEqual(de.tr("Language"), "Sprache")
        XCTAssertEqual(de.tr("Unlisted key"), "Unlisted key")
        let pl = L10n(catalogs: catalogs, setting: "pl")
        XCTAssertEqual(pl.trf("Off · {0} lights", ["3"]), "Wył. · 3 lampy")
        XCTAssertEqual(pl.trf("Off · {0} lights", ["5"]), "Wył. · 5 lamp")
        XCTAssertEqual(pl.trf("Off · {0} lights", ["12"]), "Wył. · 12 lamp")
        let auto = L10n(catalogs: catalogs, setting: "auto", preferred: ["fr-CA"])
        XCTAssertEqual(auto.code, "fr")
        XCTAssertEqual(L10n(catalogs: catalogs, setting: "xx", preferred: ["en"]).setting, "auto")
    }

    func testFormatIsOnePass() {
        XCTAssertEqual(L10n.format("{0} {1}", ["{1}", "Hue"]), "{1} Hue")
        XCTAssertEqual(L10n.format("{x} {5} {", ["a"]), "{x} {5} {")
    }

    func testRoomTextsAndErrors() throws {
        let en = L10n(catalogs: catalogsFromRepo(), setting: "en")
        let s = try XCTUnwrap(HueSnapshot.parse(line: snapshotLine))
        XCTAssertEqual(en.roomStatus(s.rooms[0]), "1 of 2 on · 1 unreachable")
        XCTAssertEqual(en.roomStatus(s.rooms[1]), "Off · 1 light")
        XCTAssertEqual(en.roomName(s.rooms[1]), "Other lights")
        var failing = s
        failing.phase = "error"
        failing.error = "Bridge not reachable (timed out)"
        failing.errorCode = "errUnreachable"
        failing.errorArgs = ["timed out"]
        XCTAssertEqual(en.errorText(failing), "Bridge not reachable (timed out)")
        XCTAssertEqual(en.summary(s), "1 of 3 on")
        let de = L10n(catalogs: catalogsFromRepo(), setting: "de")
        XCTAssertNotEqual(de.errorText(failing), en.errorText(failing))
    }

    func testRoomSymbols() throws {
        let s = try XCTUnwrap(HueSnapshot.parse(line: snapshotLine))
        XCTAssertEqual(roomSymbol(s.rooms[0]), "sofa")
        XCTAssertEqual(roomSymbol(s.rooms[1]), "lightbulb")
        XCTAssertTrue(prefersDarkGlyph("#ffd27a"))
        XCTAssertFalse(prefersDarkGlyph("#102030"))
        XCTAssertEqual(rgb("bad").r, 1.0)
    }
}

final class SettingsTests: XCTestCase {
    func testPreferencesAppearanceScheduleModeAndRulesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hue-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir.appendingPathComponent("MaprismaLights"))

        XCTAssertEqual(store.language(), "auto")
        XCTAssertEqual(store.scheduleMode(), .bridge)
        XCTAssertEqual(store.appearance(), .default)
        XCTAssertEqual(store.confirmAllOn(), false)

        try store.setLanguage("nl")
        try store.setScheduleMode(.local)
        try store.setCornerStyle(.sharp)
        try store.setBackgroundStyle(.midnight)
        try store.setFontFamily(.rounded)
        try store.setFontSize(.large)
        try store.setConfirmAllOn(true)
        try store.setFavorites(["room:1", "light:2"])
        try store.setExcludedFromAllOn(["room:bedroom"])
        try store.setRulesPaused(true)

        XCTAssertEqual(store.language(), "nl")
        XCTAssertThrowsError(try store.setLanguage("xx"))
        XCTAssertEqual(store.scheduleMode(), .local)
        XCTAssertEqual(store.cornerStyle(), .sharp)
        XCTAssertEqual(store.backgroundStyle(), .midnight)
        XCTAssertEqual(store.fontFamily(), .rounded)
        XCTAssertEqual(store.fontSize(), .large)
        XCTAssertEqual(store.confirmAllOn(), true)
        XCTAssertEqual(store.favorites(), ["room:1", "light:2"])
        XCTAssertEqual(store.excludedFromAllOn(), ["room:bedroom"])
        XCTAssertEqual(store.rulesPaused(), true)

        let rule = HueRule(
            id: "r1", name: "Link", kind: "follow", triggerKind: "light", triggerID: "a",
            targets: [HueRuleTarget(kind: "light", id: "b", action: "on")], mirrorOff: true
        )
        try store.saveRules([rule])
        XCTAssertEqual(store.loadRules(), [rule])

        let localSched = HueSchedule(
            id: "ls1", name: "Mac Wake", targetKind: "room", targetID: "r1",
            targetName: "Office", time: "08:00", source: "local"
        )
        try store.saveLocalSchedules([localSched])
        XCTAssertEqual(store.loadLocalSchedules(), [localSched])

        try store.setSkin(.synthwave)
        try store.setMenuBarIcon(.deskLamp)
        try store.setShowMenuBarCount(true)
        try store.setHotKeys([.allOff: .ctrlOpt0, .toggleSynth: .ctrlOptM])
        XCTAssertEqual(store.skin(), .synthwave)
        XCTAssertEqual(store.menuBarIcon(), .deskLamp)
        XCTAssertEqual(store.showMenuBarCount(), true)
        XCTAssertEqual(store.hotKeys(), [.allOff: .ctrlOpt0, .toggleSynth: .ctrlOptM])

        let customTheme = HueLightTheme(
            id: "t1", name: "Evening Mint", symbol: "leaf.fill", hex: "#2ec4b6",
            mirek: nil, brightness: 70, effect: "no_effect", isBuiltIn: false
        )
        try store.saveCustomThemes([customTheme] + HueLightTheme.builtIn)
        XCTAssertEqual(store.loadCustomThemes(), [customTheme])

        let fileMode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        let dirMode = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(dirMode?.intValue, 0o700)
    }

    func testDefaultDirectory() {
        #if os(macOS)
        XCTAssertTrue(SettingsStore.defaultDirectory().path.hasSuffix("/MaprismaLights"))
        #else
        XCTAssertEqual(SettingsStore.defaultDirectory(environment: ["HOME": "/Users/a"]).path, "/Users/a/.config/hue-lights")
        XCTAssertEqual(SettingsStore.defaultDirectory(environment: ["HOME": "/Users/a", "XDG_CONFIG_HOME": "/x"]).path, "/x/hue-lights")
        #endif
    }

    func testWindowFramePersistenceAndClamping() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hue-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        XCTAssertNil(store.windowFrame())

        let saved = SavedWindowFrame(x: 240, y: 180, width: 860, height: 700)
        try store.setWindowFrame(saved)
        XCTAssertEqual(store.windowFrame(), saved)

        // Clamp off-screen monitor coordinate back into a 1440x900 screen
        let offScreen = SavedWindowFrame(x: 3200, y: 900, width: 900, height: 700)
        let screen = SavedWindowFrame(x: 0, y: 25, width: 1440, height: 875)
        let clamped = offScreen.clamped(to: [screen])
        XCTAssertEqual(clamped.x, 540)
        XCTAssertEqual(clamped.y, 200)
        XCTAssertEqual(clamped.width, 900)
        XCTAssertEqual(clamped.height, 700)

        // Clamp safely on displays smaller than default 520x500 minimum
        let tinyScreen = SavedWindowFrame(x: 10, y: 20, width: 400, height: 380)
        let tinyClamped = SavedWindowFrame(x: -50, y: 500, width: 800, height: 700).clamped(to: [tinyScreen])
        XCTAssertEqual(tinyClamped.x, 10)
        XCTAssertEqual(tinyClamped.y, 20)
        XCTAssertEqual(tinyClamped.width, 400)
        XCTAssertEqual(tinyClamped.height, 380)
    }
}

final class LightThemesAndSkinsTests: XCTestCase {
    func testBuiltInThemesAndCaptureFromLight() throws {
        XCTAssertEqual(HueLightTheme.builtIn.count, 8)
        XCTAssertTrue(HueLightTheme.builtIn.allSatisfy(\.isBuiltIn))

        let light = HueLight(
            id: "11111111-1111-1111-1111-111111111111", name: "Floor Lamp",
            on: true, bri: 62.5, dimmable: true, color: "#ff7a2f",
            supportsColor: true, supportsCT: true, mirek: 380, effect: "candle"
        )
        let captured = HueLightTheme.fromLight(light, name: "Warm Corner")
        XCTAssertFalse(captured.isBuiltIn)
        XCTAssertEqual(captured.name, "Warm Corner")
        XCTAssertEqual(captured.brightness, 63)
        XCTAssertEqual(captured.effect, "candle")

        let data = try JSONEncoder().encode(captured)
        let decoded = try JSONDecoder().decode(HueLightTheme.self, from: data)
        XCTAssertEqual(decoded, captured)
    }

    func testAppSkinsAndMenuBarIconsAndHotKeys() {
        XCTAssertEqual(AppSkin.allCases.count, 6)
        XCTAssertEqual(AppSkin.retroTerminal.recommendedAppearance.fontFamily, .mono)
        XCTAssertEqual(AppSkin.cozyCabin.recommendedAppearance.fontFamily, .serif)
        XCTAssertEqual(AppSkin.synthwave.accentHex, "#ff2e93")

        XCTAssertEqual(MenuBarIconStyle.allCases.count, 8)
        XCTAssertEqual(MenuBarIconStyle.bulb.symbol(lit: true), "lightbulb.fill")
        XCTAssertEqual(MenuBarIconStyle.deskLamp.symbol(lit: false), "lamp.desk")
        XCTAssertEqual(MenuBarIconStyle.dot.symbol(lit: true), "circle.fill")

        XCTAssertEqual(HotKeyPreset.none.keyCode, nil)
        XCTAssertNotNil(HotKeyPreset.ctrlOpt0.keyCode)
        XCTAssertGreaterThan(HotKeyPreset.ctrlOpt0.carbonModifiers, 0)
    }
}

final class AudioAndEntertainmentTests: XCTestCase {
    func testAudioAnalyzerSplitsBassMidsTrebleAndDetectsBeat() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let analyzer = AudioAnalyzer(fftSize: 256, now: { now })
        let sr = 16000.0

        func sineWave(freq: Double, amp: Float) -> [Float] {
            (0..<256).map { i in amp * sinf(Float(2.0 * Double.pi * freq * Double(i) / sr)) }
        }

        // Prime rolling energy history with quiet frames
        for _ in 0..<6 {
            now += 0.05
            _ = analyzer.analyze(samples: sineWave(freq: 100, amp: 0.02), sampleRate: sr)
        }

        // Loud 100 Hz bass kick -> bass dominates & triggers beat
        now += 0.25
        let bassResult = analyzer.analyze(samples: sineWave(freq: 100, amp: 0.9), sampleRate: sr)
        XCTAssertGreaterThan(bassResult.bass, bassResult.treble)
        XCTAssertTrue(bassResult.isBeat)

        // Loud 4000 Hz treble tone -> treble dominates over bass
        now += 0.25
        let trebleResult = analyzer.analyze(samples: sineWave(freq: 4000, amp: 0.9), sampleRate: sr)
        XCTAssertGreaterThan(trebleResult.treble, trebleResult.bass)

        // DemoBeatGenerator + SynthFrameMapper produce valid Hue frames
        let beatGen = DemoBeatGenerator(bpm: 120)
        let demoLevels = beatGen.sample(at: 0.02)
        XCTAssertTrue(demoLevels.isBeat)
        let mapper = SynthFrameMapper()
        let frame = mapper.map(
            lightID: "l1", lightIndex: 0, levels: demoLevels,
            mode: .club, palette: .neon, band: .bass,
            sensitivity: 1.3, smoothness: 0.3, phase: 0.5
        )
        XCTAssertTrue((1...100).contains(frame.brightness))
        XCTAssertTrue(frame.hex.hasPrefix("#"))
    }

    func testHueStreamPacketBinaryLayoutAndEntertainmentParsing() {
        let areaID = "70000000-0000-0000-0000-000000000001"
        let ch0 = HueStreamPacket.ChannelValue(channelID: 0, c1: 0x1234, c2: 0x5678, c3: 0x9ABC)
        let ch1 = HueStreamPacket.ChannelValue(channelID: 2, c1: 0xFFFF, c2: 0x0000, c3: 0x8000)
        let packet = HueStreamPacket.encode(areaID: areaID, sequence: 7, colorSpace: .rgb16, channels: [ch0, ch1])

        // 52-byte header + 2 * 7-byte channels = 66 bytes
        XCTAssertEqual(packet.count, 66)
        XCTAssertEqual(String(data: packet.subdata(in: 0..<9), encoding: .ascii), "HueStream")
        XCTAssertEqual(packet[9], 0x02)
        XCTAssertEqual(packet[10], 0x00)
        XCTAssertEqual(packet[11], 7)
        XCTAssertEqual(packet[14], 0x00) // RGB16
        XCTAssertEqual(String(data: packet.subdata(in: 16..<52), encoding: .ascii), areaID)
        // Channel 0 payload
        XCTAssertEqual(packet[52], 0)
        XCTAssertEqual(packet[53], 0x12)
        XCTAssertEqual(packet[54], 0x34)
        XCTAssertEqual(packet[55], 0x56)
        XCTAssertEqual(packet[56], 0x78)
        XCTAssertEqual(packet[57], 0x9A)
        XCTAssertEqual(packet[58], 0xBC)
        // Channel 1 payload
        XCTAssertEqual(packet[59], 2)
        XCTAssertEqual(packet[60], 0xFF)
        XCTAssertEqual(packet[61], 0xFF)

        // Hex clientKey parsing
        XCTAssertEqual(HueStreamPacket.hexKeyBytes("00112233445566778899AABBCCDDEEFF")?.count, 16)
        XCTAssertNil(HueStreamPacket.hexKeyBytes("short"))

        // entertainment_configuration resource parsing in HueModelBuilder
        let resources: [[String: Any]] = [
            [
                "id": areaID,
                "type": "entertainment_configuration",
                "metadata": ["name": "TV Sync"],
                "channels": [
                    ["channel_id": 0, "members": [["service": ["rid": "11111111-1111-1111-1111-111111111111", "rtype": "entertainment"]]]],
                ],
            ],
        ]
        let model = HueModelBuilder.build(from: resources)
        XCTAssertEqual(model.entertainmentAreas.count, 1)
        XCTAssertEqual(model.entertainmentAreas[0].name, "TV Sync")
        XCTAssertEqual(model.entertainmentAreas[0].channels.first?.channelID, 0)
    }
}

final class DebouncerTests: XCTestCase {
    func testThrottleTrailingAndRelease() {
        var clock = Date(timeIntervalSince1970: 0)
        var sent: [(String, Int)] = []
        let queue = DispatchQueue(label: "debounce")
        let debouncer = BrightnessDebouncer(interval: 0.15, queue: queue, now: { clock }) { sent.append(($0, $1)) }
        queue.sync {
            debouncer.update("room:a", 10)
            clock += 0.05
            debouncer.update("room:a", 20)
            clock += 0.05
            debouncer.update("room:a", 30)
            XCTAssertEqual(debouncer.value(for: "room:a"), 30)
            debouncer.update("light:b", 70)
        }
        XCTAssertEqual(sent.map(\.1), [10, 70])
        clock += 0.2
        let trailing = expectation(description: "trailing")
        queue.asyncAfter(deadline: .now() + 0.3) { trailing.fulfill() }
        wait(for: [trailing], timeout: 2)
        queue.sync {
            XCTAssertEqual(sent.map(\.1), [10, 70, 30])
            debouncer.finish("room:a")
            XCTAssertNil(debouncer.value(for: "room:a"))
            clock += 0.01
            debouncer.update("light:b", 75)
            debouncer.finish("light:b")
        }
        XCTAssertEqual(sent.map(\.1), [10, 70, 30, 75])
        XCTAssertEqual(sent.last?.0, "light:b")
    }
}

final class FloorplanTests: XCTestCase {
    private let livingID = "10000000-0000-0000-0000-000000000001"
    private let officeID = "10000000-0000-0000-0000-000000000002"
    private let entAreaID = "70000000-0000-0000-0000-000000000001"

    func testAllSixPrototypesAndAutoMatching() {
        let light1 = HueLight(id: "30000000-0000-0000-0000-000000000001", deviceID: "80000000-0000-0000-0000-000000000001", name: "Stehlampe", on: true, bri: 75, dimmable: true, color: "#ffaa44")
        let light2 = HueLight(id: "30000000-0000-0000-0000-000000000002", deviceID: "80000000-0000-0000-0000-000000000002", name: "Schreibtisch", on: true, bri: 90, dimmable: true, color: "#eef6ff")
        let snap = HueSnapshot(
            phase: "ok",
            rooms: [
                HueRoom(hueID: livingID, kind: "room", name: "Wohnzimmer", groupedLight: "20000000-0000-0000-0000-000000000001", on: true, bri: 75, onCount: 1, archetype: "living_room", color: "#ffaa44", lights: [light1], scenes: []),
                HueRoom(hueID: officeID, kind: "room", name: "Büro", groupedLight: "20000000-0000-0000-0000-000000000002", on: true, bri: 90, onCount: 1, archetype: "office", color: "#eef6ff", lights: [light2], scenes: []),
            ],
            lightCount: 2,
            onCount: 2,
            entertainmentAreas: [
                HueEntertainmentArea(id: entAreaID, name: "Wohnzimmer Sync", channels: [HueEntertainmentChannel(channelID: 0, lightIDs: [light1.id])]),
            ]
        )

        XCTAssertEqual(FloorplanTemplate.allCases.count, 6)
        for tpl in FloorplanTemplate.allCases {
            let doc = FloorplanTemplate.build(template: tpl, snapshot: snap, bridgeID: "001788FFFE123456")
            XCTAssertEqual(doc.templateID, tpl.rawValue)
            XCTAssertEqual(doc.bridgeID, "001788FFFE123456")
            XCTAssertFalse(doc.boxes.isEmpty, "Template \(tpl.rawValue) should create boxes")
            XCTAssertFalse(doc.lamps.isEmpty, "Template \(tpl.rawValue) should place lights")
            if tpl != .deskStudio {
                XCTAssertTrue(doc.boxes.contains(where: { $0.hueID == livingID }), "Living room should auto-match in \(tpl.rawValue)")
                XCTAssertTrue(doc.boxes.contains(where: { $0.hueID == officeID }), "Office should auto-match in \(tpl.rawValue)")
            }
        }
    }

    func testContainmentDiffsSyncPlanAndEntertainmentNormalization() throws {
        let l1 = HueLight(id: "30000000-0000-0000-0000-000000000001", deviceID: "80000000-0000-0000-0000-000000000001", name: "Lamp A", on: true, bri: 80, dimmable: true, color: "#ffd27a")
        let l2 = HueLight(id: "30000000-0000-0000-0000-000000000002", deviceID: "80000000-0000-0000-0000-000000000002", name: "Lamp B", on: true, bri: 60, dimmable: true, color: "#38bdf8")
        let snap = HueSnapshot(
            phase: "ok",
            rooms: [
                HueRoom(hueID: livingID, kind: "room", name: "Living Room", groupedLight: "20000000-0000-0000-0000-000000000001", on: true, bri: 80, onCount: 1, archetype: "living_room", color: "#ffd27a", lights: [l1], scenes: []),
                HueRoom(hueID: officeID, kind: "room", name: "Office", groupedLight: "20000000-0000-0000-0000-000000000002", on: true, bri: 60, onCount: 1, archetype: "office", color: "#38bdf8", lights: [l2], scenes: []),
            ],
            lightCount: 2,
            onCount: 2
        )

        let livingBox = FloorplanBox(id: "b1", kind: "room", hueID: livingID, name: "Living Room", archetype: "living_room", x: 0, y: 0, width: 400, height: 200, entertainmentAreaID: entAreaID)
        let officeBox = FloorplanBox(id: "b2", kind: "room", hueID: officeID, name: "Studio", archetype: "office", x: 400, y: 0, width: 400, height: 200)
        // Move Lamp A into Office box; keep Lamp B inside Office box
        var doc = FloorplanDocument(
            bridgeID: "001788FFFE123456",
            autoSync: true,
            boxes: [livingBox, officeBox],
            lamps: [
                l1.id: FloorplanLampPlacement(x: 500, y: 100, z: 0.5),
                l2.id: FloorplanLampPlacement(x: 600, y: 100, z: -0.25),
            ]
        )

        XCTAssertEqual(FloorplanSpatial.boxContaining(x: 500, y: 100, in: doc.boxes)?.id, "b2")
        let diffs = FloorplanSpatial.pendingRoomMembershipDiffs(floorplan: doc, snapshot: snap)
        XCTAssertEqual(diffs.count, 1)
        XCTAssertEqual(diffs[0].lightID, l1.id)
        XCTAssertEqual(diffs[0].fromRoomID, livingID)
        XCTAssertEqual(diffs[0].toRoomID, officeID)

        let plan = FloorplanSpatial.buildSyncPlan(floorplan: doc, snapshot: snap)
        XCTAssertTrue(plan.hasRoomOrMetaChanges)
        XCTAssertEqual(plan.boxesToUpdateMeta.map(\.id), ["b2"]) // renamed Office -> Studio
        XCTAssertEqual(plan.entertainmentBoxes.map(\.id), ["b1"])

        // Place Lamp A at top-left (x=0,y=0) and Lamp B at bottom-right (x=400,y=200) inside livingBox
        doc.lamps[l1.id] = FloorplanLampPlacement(x: 0, y: 0, z: 0.8)
        doc.lamps[l2.id] = FloorplanLampPlacement(x: 400, y: 200, z: -0.5)
        let positions = FloorplanSpatial.entertainmentPositions(forBox: livingBox, floorplan: doc, snapshot: snap)
        let p1 = try XCTUnwrap(positions[l1.id])
        XCTAssertEqual(p1.0, -1.0, accuracy: 0.001)
        XCTAssertEqual(p1.1, 1.0, accuracy: 0.001)
        XCTAssertEqual(p1.2, 0.8, accuracy: 0.001)
        let p2 = try XCTUnwrap(positions[l2.id])
        XCTAssertEqual(p2.0, 1.0, accuracy: 0.001)
        XCTAssertEqual(p2.1, 0.0, accuracy: 0.001)
        XCTAssertEqual(p2.2, -0.5, accuracy: 0.001)
    }

    func testFloorplanBackgroundSanitizationAndPersistence() throws {
        // Reject path traversal, hidden files, and unsupported extensions
        XCTAssertNil(FloorplanBackground.sanitizeFileName("../secret.png"))
        XCTAssertNil(FloorplanBackground.sanitizeFileName("sub/floor.png"))
        XCTAssertNil(FloorplanBackground.sanitizeFileName("floor\\plan.jpg"))
        XCTAssertNil(FloorplanBackground.sanitizeFileName(".hidden.png"))
        XCTAssertNil(FloorplanBackground.sanitizeFileName("vector.svg"))
        XCTAssertEqual(FloorplanBackground.sanitizeFileName("floorplan-bg-demo.png"), "floorplan-bg-demo.png")

        let bg = FloorplanBackground(fileName: "floorplan-bg.jpg", opacity: 2.5, fit: .cover)
        XCTAssertEqual(bg.opacity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(bg.fit, .cover)
        let bgLow = FloorplanBackground(fileName: "floorplan-bg.webp", opacity: -0.4, fit: .contain)
        XCTAssertEqual(bgLow.opacity, FloorplanBackground.minOpacity, accuracy: 0.0001)

        // Round-trip per-bridge floorplan.json + background image in temp SettingsStore
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hue-fp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SettingsStore(directory: tempDir)

        let doc = FloorplanDocument(
            bridgeID: "001788FFFE123456",
            autoSync: true,
            background: bg,
            boxes: [FloorplanBox(id: "b1", kind: "room", name: "Hall", x: 20, y: 40, width: 200, height: 150)],
            stamps: [FloorplanStamp(id: "s1", kind: "door", x: 30, y: 40, rotation: 90)],
            lamps: ["30000000-0000-0000-0000-000000000001": FloorplanLampPlacement(x: 80, y: 90, z: 0.2, icon: .floor)]
        )
        try store.saveFloorplan(doc)
        let loaded = try XCTUnwrap(store.loadFloorplan(bridgeID: "001788FFFE123456"))
        XCTAssertEqual(loaded, doc)
        XCTAssertTrue(loaded.autoSync)

        // Save valid PNG background & reject unsupported extension
        let fakePNG = tempDir.appendingPathComponent("input.png")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fakePNG)
        let savedName = try store.saveFloorplanBackground(from: fakePNG, bridgeID: "001788FFFE123456")
        XCTAssertTrue(savedName.hasSuffix(".png"))
        XCTAssertNotNil(store.floorplanBackgroundURL(fileName: savedName))
        XCTAssertNil(store.floorplanBackgroundURL(fileName: "../input.png"))
        store.clearFloorplanBackground(fileName: savedName)
        XCTAssertNil(store.floorplanBackgroundURL(fileName: savedName))

        let badFile = tempDir.appendingPathComponent("bad.txt")
        try Data("nope".utf8).write(to: badFile)
        XCTAssertThrowsError(try store.saveFloorplanBackground(from: badFile))
    }

    func testLampIconCodableRoundTripAndFallback() throws {
        XCTAssertEqual(LampIcon.allCases.count, 12)
        for icon in LampIcon.allCases {
            XCTAssertFalse(icon.sfSymbol(lit: true).isEmpty)
            XCTAssertFalse(icon.sfSymbol(lit: false).isEmpty)
            let lamp = FloorplanLamp(x: 10, y: 20, z: 0, icon: icon)
            let data = try JSONEncoder().encode(lamp)
            let decoded = try JSONDecoder().decode(FloorplanLamp.self, from: data)
            XCTAssertEqual(decoded.icon, icon)
        }
        // Missing icon key in JSON falls back to .bulb
        let missingIcon = try JSONDecoder().decode(FloorplanLamp.self, from: Data(#"{"x":50,"y":60,"z":0}"#.utf8))
        XCTAssertEqual(missingIcon.icon, .bulb)
        // Unknown icon falls back to .bulb; legacy aliases decode cleanly
        let unknownIcon = try JSONDecoder().decode(FloorplanLamp.self, from: Data(#"{"x":50,"y":60,"z":0,"icon":"spaceship"}"#.utf8))
        XCTAssertEqual(unknownIcon.icon, .bulb)
        let legacyFloor = try JSONDecoder().decode(FloorplanLamp.self, from: Data(#"{"x":50,"y":60,"z":0,"icon":"floor_lamp"}"#.utf8))
        XCTAssertEqual(legacyFloor.icon, .floor)
        XCTAssertEqual(LampIcon.inferred(for: "TV Play Bars"), .bar)
        XCTAssertEqual(LampIcon.inferred(for: "Bedside Left"), .table)
    }

    func testFloorplanV2PolygonsMultiFloorAndLightingPlanner() throws {
        // 1. L-shape polygon room: ray-casting containment excludes the cut-out notch!
        let lBox = FloorplanBox(
            id: "l-room",
            kind: "room",
            name: "Living L",
            archetype: "living_room",
            x: 0, y: 0, width: 400, height: 400
        ).applyingShape(.lShape)
        XCTAssertTrue(lBox.isPolygon)
        XCTAssertEqual(lBox.effectivePoints.count, 6)
        XCTAssertTrue(lBox.contains(x: 100, y: 100))   // inside upper-left arm
        XCTAssertTrue(lBox.contains(x: 100, y: 350))   // inside bottom-left leg
        XCTAssertFalse(lBox.contains(x: 350, y: 350))  // inside L-notch cut-out!
        XCTAssertLessThan(lBox.area, 400.0 * 400.0)
        XCTAssertGreaterThan(lBox.areaSquareMeters(pxPerMeter: 50.0), 30.0)

        // Vertex insert, move, remove, and translation
        let splitBox = lBox.insertingVertex(afterEdge: 0, at: FloorplanPoint(x: 200, y: -20))
        XCTAssertEqual(splitBox.effectivePoints.count, 7)
        XCTAssertEqual(splitBox.minY, -20, accuracy: 0.01)
        let trimmedBox = splitBox.removingVertex(at: 1)
        XCTAssertEqual(trimmedBox.effectivePoints.count, 6)
        let movedBox = lBox.translated(dx: 50, dy: 25)
        XCTAssertEqual(movedBox.x, 50, accuracy: 0.01)
        XCTAssertTrue(movedBox.contains(x: 150, y: 125))

        // 2. Multi-floor 2-Story Family House + sample planned lighting & RoomLightingAnalysis
        let snap = HueSnapshot(phase: "ok")
        var house = FloorplanTemplate.build(template: .familyHouse, snapshot: snap)
        XCTAssertEqual(house.floors.count, 2)
        XCTAssertFalse(house.boxes(onFloor: "eg").isEmpty)
        XCTAssertFalse(house.boxes(onFloor: "og").isEmpty)
        house.plannedLights = FloorplanTemplate.samplePlannedLights(for: house)
        XCTAssertFalse(house.plannedLights.isEmpty)
        let living = try XCTUnwrap(house.boxes(onFloor: "eg").first(where: { $0.archetype == "living_room" }))
        let analysis = RoomLightingAnalysis.compute(for: living, floorplan: house, snapshot: snap, includePlanned: true)
        XCTAssertGreaterThan(analysis.plannedLumens, 0)
        XCTAssertGreaterThan(analysis.lux, 0)

        // 3. Round-trip v2 JSON + backward-compatible v1 JSON decode
        let encoded = try JSONEncoder().encode(house)
        let decoded = try JSONDecoder().decode(FloorplanDocument.self, from: encoded)
        XCTAssertEqual(decoded.floors.count, 2)
        XCTAssertEqual(decoded.plannedLights.count, house.plannedLights.count)

        let legacyV1 = Data(#"{"version":1,"bridge_id":"abc","boxes":[{"id":"r1","kind":"room","name":"Old","x":0,"y":0,"w":200,"h":200}],"lamps":{"l1":{"x":50,"y":50,"z":0}}}"#.utf8)
        let decodedV1 = try JSONDecoder().decode(FloorplanDocument.self, from: legacyV1)
        XCTAssertEqual(decodedV1.floors.count, 1)
        XCTAssertEqual(decodedV1.boxes.first?.floorID, "eg")
        XCTAssertEqual(decodedV1.lamps["l1"]?.floorID, "eg")
    }

    @MainActor
    func testDemoBridgeClientTwoWayMutations() async throws {
        let demo = DemoBridgeClient()

        // Rename light with markup sanitization
        demo.renameLight(id: DemoBridgeClient.deskLampID, name: "<b>Studio</b> Desk")
        XCTAssertEqual(demo.currentSnapshot().light(DemoBridgeClient.deskLampID)?.name, "bStudio/b Desk")

        // Create room moving desk lamp device out of Office
        let deskDevice = try XCTUnwrap(demo.currentSnapshot().light(DemoBridgeClient.deskLampID)?.deviceID)
        XCTAssertFalse(deskDevice.isEmpty)
        let createdRoomID = await demo.createRoom(kind: "room", name: "Reading Nook", archetype: "lounge", deviceIDs: [deskDevice])
        let newRoomID = try XCTUnwrap(createdRoomID)
        let afterCreate = demo.currentSnapshot()
        XCTAssertTrue(afterCreate.room(newRoomID)?.lights.contains(where: { $0.id == DemoBridgeClient.deskLampID }) == true)
        XCTAssertFalse(afterCreate.room(DemoBridgeClient.officeRoomID)?.lights.contains(where: { $0.id == DemoBridgeClient.deskLampID }) == true)

        // Update room name & create scene from current state
        let updated = await demo.updateRoom(id: newRoomID, kind: "room", name: "Cozy Nook", archetype: "living_room", deviceIDs: nil)
        XCTAssertTrue(updated)
        XCTAssertEqual(demo.currentSnapshot().room(newRoomID)?.name, "Cozy Nook")

        let createdSceneID = await demo.createSceneFromRoom(roomID: newRoomID, name: "Late Night")
        let sceneID = try XCTUnwrap(createdSceneID)
        XCTAssertTrue(demo.currentSnapshot().room(newRoomID)?.scenes.contains(where: { $0.id == sceneID && $0.name == "Late Night" }) == true)

        // Schedule scene on that room
        demo.createSchedule(HueScheduleDraft(
            name: "Night Nook",
            targetKind: "room",
            targetID: newRoomID,
            targetName: "Cozy Nook",
            triggerKind: "time",
            time: "21:30",
            action: "scene",
            bri: nil,
            sceneID: sceneID
        ))
        XCTAssertTrue(demo.currentSnapshot().schedules.contains(where: { $0.action == "scene" && $0.sceneID == sceneID }))

        // Entertainment locations sync
        let entOK = await demo.updateEntertainmentLocations(
            areaID: entAreaID,
            positions: [DemoBridgeClient.deskLampID: (0.25, 0.75, 0.5)]
        )
        XCTAssertTrue(entOK)
        XCTAssertEqual(demo.entertainmentPositions[entAreaID]?[DemoBridgeClient.deskLampID]?.0 ?? 0, 0.25, accuracy: 0.001)

        // Delete room moves lights to "other"
        let deleted = await demo.deleteRoom(id: newRoomID, kind: "room")
        XCTAssertTrue(deleted)
        XCTAssertNil(demo.currentSnapshot().room(newRoomID))
        XCTAssertNotNil(demo.currentSnapshot().light(DemoBridgeClient.deskLampID))
    }

    func testBridgeProMotionAwareAndSensorsModelSSEAndRules() throws {
        let lightID = "11111111-1111-1111-1111-111111111111"
        let lightDevID = "22222222-2222-2222-2222-222222222222"
        let bridgeDevID = "22222222-2222-2222-2222-222222222220"
        let roomID = "33333333-3333-3333-3333-333333333333"
        let groupID = "44444444-4444-4444-4444-444444444444"
        let candID = "55555555-5555-5555-5555-555555555551"
        let convID = "55555555-5555-5555-5555-555555555552"
        let areaID = "55555555-5555-5555-5555-555555555553"
        let motionDevID = "66666666-6666-6666-6666-666666666661"
        let motionID = "66666666-6666-6666-6666-666666666662"
        let tempID = "66666666-6666-6666-6666-666666666663"
        let luxID = "66666666-6666-6666-6666-666666666664"
        let powerID = "66666666-6666-6666-6666-666666666665"
        let contactDevID = "77777777-7777-7777-7777-777777777771"
        let contactID = "77777777-7777-7777-7777-777777777772"
        let btnDevID = "88888888-8888-8888-8888-888888888881"
        let btn1ID = "88888888-8888-8888-8888-888888888882"
        let btn2ID = "88888888-8888-8888-8888-888888888883"

        let resources: [[String: Any]] = [
            ["id": "99999999-9999-9999-9999-999999999991", "type": "bridge", "owner": ["rid": bridgeDevID, "rtype": "device"]],
            ["id": bridgeDevID, "type": "device", "product_data": ["model_id": "BSB003"]],
            ["id": lightID, "type": "light", "owner": ["rid": lightDevID, "rtype": "device"], "metadata": ["name": "Pendant"], "on": ["on": true], "dimming": ["brightness": 80.0]],
            ["id": lightDevID, "type": "device", "services": [["rid": lightID, "rtype": "light"]]],
            ["id": groupID, "type": "grouped_light", "on": ["on": true]],
            ["id": roomID, "type": "room", "metadata": ["name": "Living Room", "archetype": "living_room"], "children": [["rid": lightDevID, "rtype": "device"], ["rid": motionDevID, "rtype": "device"]], "services": [["rid": groupID, "rtype": "grouped_light"]]],
            ["id": candID, "type": "motion_area_candidate", "owner": ["rid": lightDevID, "rtype": "device"]],
            ["id": convID, "type": "convenience_area_motion", "owner": ["rid": areaID, "rtype": "motion_area_configuration"], "enabled": true, "motion": ["motion": true, "motion_valid": true]],
            ["id": areaID, "type": "motion_area_configuration", "name": "Living MotionAware", "enabled": true, "group": ["rid": roomID, "rtype": "room"], "convenience_area_motion": ["rid": convID, "rtype": "convenience_area_motion"], "sensitivity": ["sensitivity": 3, "sensitivity_max": 4], "participants": [["rid": candID, "rtype": "motion_area_candidate"]]],
            ["id": motionDevID, "type": "device", "metadata": ["name": "Hall Motion"]],
            ["id": motionID, "type": "motion", "owner": ["rid": motionDevID, "rtype": "device"], "enabled": true, "motion": ["motion": false], "sensitivity": ["sensitivity": 2, "sensitivity_max": 4]],
            ["id": tempID, "type": "temperature", "owner": ["rid": motionDevID, "rtype": "device"], "temperature": ["temperature": 21.44]],
            ["id": luxID, "type": "light_level", "owner": ["rid": motionDevID, "rtype": "device"], "light": ["light_level": 10001]],
            ["id": powerID, "type": "device_power", "owner": ["rid": motionDevID, "rtype": "device"], "power_state": ["battery_level": 88, "battery_state": "normal"]],
            ["id": contactDevID, "type": "device", "metadata": ["name": "Front Door"]],
            ["id": contactID, "type": "contact", "owner": ["rid": contactDevID, "rtype": "device"], "enabled": true, "contact_report": ["state": "no_contact"]],
            ["id": btnDevID, "type": "device", "metadata": ["name": "Dimmer Switch"]],
            ["id": btn1ID, "type": "button", "owner": ["rid": btnDevID, "rtype": "device"], "metadata": ["control_id": 1], "button": ["button_report": ["event": "short_release"]]],
            ["id": btn2ID, "type": "button", "owner": ["rid": btnDevID, "rtype": "device"], "metadata": ["control_id": 2]],
        ]

        let built = HueModelBuilder.build(from: resources)
        XCTAssertTrue(built.isPro)
        XCTAssertEqual(built.bridgeModelID, "BSB003")
        XCTAssertEqual(built.motionAreaCandidates, 1)
        XCTAssertEqual(built.motionAreas.count, 1)
        XCTAssertEqual(built.motionAreas[0].lightIDs, [lightID])
        XCTAssertTrue(built.rooms[0].lights[0].motionAware)
        XCTAssertTrue(built.rooms[0].lights[0].motionActive)
        XCTAssertEqual(built.sensors.count, 3)

        let motionSensor = try XCTUnwrap(built.sensors.first { $0.kind == "motion" })
        XCTAssertEqual(motionSensor.temperature, 21.4)
        XCTAssertEqual(motionSensor.lux, 10.0)
        XCTAssertEqual(motionSensor.battery, 88)
        let contactSensor = try XCTUnwrap(built.sensors.first { $0.kind == "contact" })
        XCTAssertTrue(contactSensor.open)
        let switchSensor = try XCTUnwrap(built.sensors.first { $0.kind == "button" })
        XCTAssertEqual(switchSensor.buttonIDs.count, 2)

        // Floorplan without "sensors" decodes cleanly with empty dict
        let legacyFP = try JSONDecoder().decode(FloorplanDocument.self, from: Data(#"{"version":1}"#.utf8))
        XCTAssertTrue(legacyFP.sensors.isEmpty)

        // SSE parser extracts motion, contact, button, temperature, light_level, device_power
        let ssePayload = #"[{"type":"update","data":[{"id":"\#(motionID)","type":"motion","motion":{"motion":true}},{"id":"\#(contactID)","type":"contact","contact_report":{"state":"contact"}}]}]"#
        let updates = SSEParser.parsePayload(ssePayload)
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].motion, true)
        XCTAssertEqual(updates[1].contactOpen, false)

        // RuleEngine evaluates sensor triggers & mirrorOff
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = HueRule(
            id: "sr1", name: "Hall Motion", kind: "follow",
            triggerKind: "motion", triggerID: motionID, triggerState: "motion",
            targets: [HueRuleTarget(kind: "light", id: lightID, action: "on")],
            mirrorOff: true
        )
        let engine = RuleEngine(rules: [rule], now: { now })
        let snap = HueSnapshot(phase: "ok", rooms: built.rooms, lightCount: 1, onCount: 1, motionAreas: built.motionAreas, sensors: built.sensors)
        let firedOn = engine.evaluateSensorEvent(kind: "motion", id: motionID, state: "motion", snapshot: snap)
        XCTAssertEqual(firedOn.first?.on, true)
        now += 5
        let firedOff = engine.evaluateSensorEvent(kind: "motion", id: motionID, state: "clear", snapshot: snap)
        XCTAssertEqual(firedOff.first?.on, false)
    }

    @MainActor
    func testBridgeInfoMotionAreaCandidatesAndUncalibratedBridgePro() throws {
        // Backwards-compatible Codable decode when motion_area_candidates is absent
        let legacyData = Data(#"{"ip":"192.168.1.50","name":"Hue","model":"BSB002"}"#.utf8)
        let legacyBridge = try JSONDecoder().decode(BridgeInfo.self, from: legacyData)
        XCTAssertFalse(legacyBridge.isPro)
        XCTAssertEqual(legacyBridge.motionAreaCandidates, 0)

        // Codable round-trip with Bridge Pro + motionAreaCandidates
        let proBridge = BridgeInfo(ip: "192.168.1.60", name: "Hue Pro", model: "BSB003", modelID: "BSB003", isPro: true, motionAreaCandidates: 4)
        let encoded = try JSONEncoder().encode(proBridge)
        let decodedPro = try JSONDecoder().decode(BridgeInfo.self, from: encoded)
        XCTAssertEqual(decodedPro, proBridge)
        XCTAssertTrue(decodedPro.isPro)
        XCTAssertEqual(decodedPro.motionAreaCandidates, 4)

        // Snapshot JSON parser reads motion_area_candidates and defaults safely to 0
        let snapWithCands = try XCTUnwrap(HueSnapshot.parse(line: #"{"phase":"ok","bridge":{"ip":"192.168.1.60","name":"Hue Pro","model":"BSB003","model_id":"BSB003","is_pro":true,"motion_area_candidates":3}}"#))
        XCTAssertTrue(snapWithCands.bridge?.isPro == true)
        XCTAssertEqual(snapWithCands.bridge?.motionAreaCandidates, 3)

        let snapLegacy = try XCTUnwrap(HueSnapshot.parse(line: #"{"phase":"ok","bridge":{"ip":"192.168.1.50","name":"Hue","model":"BSB002"}}"#))
        XCTAssertEqual(snapLegacy.bridge?.motionAreaCandidates, 0)

        // Uncalibrated Bridge Pro: 3 motion_area_candidate resources, 0 motion_area_configuration
        let bridgeDevID = "22222222-2222-2222-2222-222222222220"
        let resources: [[String: Any]] = [
            ["id": "99999999-9999-9999-9999-999999999991", "type": "bridge", "owner": ["rid": bridgeDevID, "rtype": "device"]],
            ["id": bridgeDevID, "type": "device", "product_data": ["model_id": "BSB003"]],
            ["id": "55555555-5555-5555-5555-555555555501", "type": "motion_area_candidate"],
            ["id": "55555555-5555-5555-5555-555555555502", "type": "motion_area_candidate"],
            ["id": "55555555-5555-5555-5555-555555555503", "type": "motion_area_candidate"],
        ]
        let built = HueModelBuilder.build(from: resources)
        XCTAssertTrue(built.isPro)
        XCTAssertEqual(built.motionAreaCandidates, 3)
        XCTAssertTrue(built.motionAreas.isEmpty)

        // DemoBridgeClient exposes Bridge Pro candidate count
        let demoSnap = DemoBridgeClient().currentSnapshot()
        XCTAssertTrue(demoSnap.bridge?.isPro == true)
        XCTAssertEqual(demoSnap.bridge?.motionAreaCandidates, 3)
    }
}

final class AskAIAndMCPTests: XCTestCase {
    func testAskAISettingsDefaultOffAndDecodeBackwardsCompatible() throws {
        // Empty JSON decodes cleanly with askAIEnabled == false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.askAIEnabled)
        XCTAssertEqual(decoded.askAIOllamaURL, AppSettings.defaultAskAIOllamaURL)
        XCTAssertEqual(decoded.askAIModel, "")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hue-askai-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        XCTAssertFalse(store.askAIEnabled())
        XCTAssertEqual(store.askAIOllamaURL(), "http://127.0.0.1:11434")
        XCTAssertEqual(store.askAIModel(), "")

        try store.setAskAIEnabled(true)
        try store.setAskAIOllamaURL("http://localhost:11434")
        try store.setAskAIModel("llama3.2")
        XCTAssertTrue(store.askAIEnabled())
        XCTAssertEqual(store.askAIOllamaURL(), "http://localhost:11434")
        XCTAssertEqual(store.askAIModel(), "llama3.2")
        XCTAssertEqual(store.appSettings(), AppSettings(askAIEnabled: true, askAIOllamaURL: "http://localhost:11434", askAIModel: "llama3.2"))
    }

    func testLoopbackOllamaURLGuard() {
        XCTAssertEqual(HueAskAIEngine.validatedLocalOllamaEndpoint("http://127.0.0.1:11434")?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(HueAskAIEngine.validatedLocalOllamaEndpoint("http://localhost:11434/")?.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertEqual(HueAskAIEngine.validatedLocalOllamaEndpoint("http://127.0.0.1:11434/api/chat")?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertNil(HueAskAIEngine.validatedLocalOllamaEndpoint("http://192.168.1.10:11434"))
        XCTAssertNil(HueAskAIEngine.validatedLocalOllamaEndpoint("http://example.com:11434"))
        XCTAssertNil(HueAskAIEngine.validatedLocalOllamaEndpoint("https://api.openai.com/v1"))
        XCTAssertNil(HueAskAIEngine.validatedLocalOllamaEndpoint("http://user:pass@127.0.0.1:11434"))
        XCTAssertNil(HueAskAIEngine.validatedLocalOllamaEndpoint("ftp://localhost:11434"))
    }

    @MainActor
    func testAskAIParserEnglishAndGermanCommands() {
        let demo = DemoBridgeClient()
        let snap = demo.currentSnapshot()
        let engine = HueAskAIEngine()

        // All on / off (EN & DE)
        XCTAssertEqual(engine.parse("All lights off", snapshot: snap).calls.first?.name, "hue_all_off")
        XCTAssertEqual(engine.parse("Alle Lichter aus", snapshot: snap).calls.first?.name, "hue_all_off")
        XCTAssertEqual(engine.parse("Alle Lampen an", snapshot: snap).calls.first?.name, "hue_all_on")

        // Status queries (EN & DE)
        XCTAssertEqual(engine.parse("Which lights are on?", snapshot: snap).calls.first?.name, "hue_status")
        XCTAssertEqual(engine.parse("Welche Lichter sind an?", snapshot: snap).calls.first?.name, "hue_status")

        // Room brightness + warmth (EN & DE)
        let dimWarm = engine.parse("Dim Living Room to 40% warm", snapshot: snap)
        XCTAssertEqual(dimWarm.calls.first?.name, "hue_set_room")
        XCTAssertEqual(dimWarm.calls.first?.arguments["target"]?.stringValue, DemoBridgeClient.livingRoomID)
        XCTAssertEqual(dimWarm.calls.first?.arguments["bri"]?.intValue, 40)
        XCTAssertNotNil(dimWarm.calls.first?.arguments["mirek"]?.intValue)

        let deWarm = engine.parse("Wohnzimmer auf 30% warmweiß", snapshot: snap)
        XCTAssertEqual(deWarm.calls.first?.name, "hue_set_room")
        XCTAssertEqual(deWarm.calls.first?.arguments["target"]?.stringValue, DemoBridgeClient.livingRoomID)
        XCTAssertEqual(deWarm.calls.first?.arguments["bri"]?.intValue, 30)

        // Light hex color, Kelvin & native effect
        let hexCmd = engine.parse("Set Floor Lamp to #ff00aa", snapshot: snap)
        XCTAssertEqual(hexCmd.calls.first?.name, "hue_set_light")
        XCTAssertEqual(hexCmd.calls.first?.arguments["color"]?.stringValue, "#ff00aa")

        let kelvinCmd = engine.parse("Desk Lamp 2700K", snapshot: snap)
        XCTAssertEqual(kelvinCmd.calls.first?.name, "hue_set_light")
        XCTAssertEqual(kelvinCmd.calls.first?.arguments["kelvin"]?.intValue, 2700)

        let effectCmd = engine.parse("Floor Lamp candle", snapshot: snap)
        XCTAssertEqual(effectCmd.calls.first?.name, "hue_set_light")
        XCTAssertEqual(effectCmd.calls.first?.arguments["effect"]?.stringValue, "candle")

        // Light theme application
        let themeCmd = engine.parse("Apply Cyberpunk Neon to Office", snapshot: snap)
        XCTAssertEqual(themeCmd.calls.first?.name, "hue_apply_theme")
        XCTAssertEqual(themeCmd.calls.first?.arguments["theme"]?.stringValue, "builtin-cyberpunk-neon")
        XCTAssertEqual(themeCmd.calls.first?.arguments["target"]?.stringValue, DemoBridgeClient.officeRoomID)

        // Scene recall (DE room synonym)
        let sceneCmd = engine.parse("Relax im Wohnzimmer", snapshot: snap)
        XCTAssertEqual(sceneCmd.calls.first?.name, "hue_recall_scene")
        XCTAssertEqual(sceneCmd.calls.first?.arguments["room"]?.stringValue, DemoBridgeClient.livingRoomID)

        // Schedule creation (EN & DE, clock + sunset)
        let schedEN = engine.parse("Turn on Hallway at 07:30 on weekdays", snapshot: snap)
        XCTAssertEqual(schedEN.calls.first?.name, "hue_create_schedule")
        XCTAssertEqual(schedEN.calls.first?.arguments["time"]?.stringValue, "07:30")
        XCTAssertEqual(schedEN.calls.first?.arguments["days"]?.arrayValue?.count, 5)

        let schedDE = engine.parse("Wohnzimmer bei Sonnenuntergang ausschalten", snapshot: snap)
        XCTAssertEqual(schedDE.calls.first?.name, "hue_create_schedule")
        XCTAssertEqual(schedDE.calls.first?.arguments["trigger_kind"]?.stringValue, "sunset")
        XCTAssertEqual(schedDE.calls.first?.arguments["action"]?.stringValue, "off")

        // Rule creation (physical sensor, lamp-to-lamp exclusive, MotionAware)
        let sensorRule = engine.parse("When Hallway Motion detects motion, turn on Hallway", snapshot: snap)
        XCTAssertEqual(sensorRule.calls.first?.name, "hue_create_rule")
        XCTAssertEqual(sensorRule.calls.first?.arguments["trigger_kind"]?.stringValue, "motion")
        XCTAssertEqual(sensorRule.calls.first?.arguments["trigger"]?.stringValue, DemoBridgeClient.hallwayMotionSensorID)
        XCTAssertEqual(sensorRule.calls.first?.arguments["target"]?.stringValue, DemoBridgeClient.hallwayRoomID)

        let lampRule = engine.parse("When Desk Lamp turns on, turn off Ceiling Pendant", snapshot: snap)
        XCTAssertEqual(lampRule.calls.first?.name, "hue_create_rule")
        XCTAssertEqual(lampRule.calls.first?.arguments["kind"]?.stringValue, "exclusive")
        XCTAssertEqual(lampRule.calls.first?.arguments["action"]?.stringValue, "off")

        let maRule = engine.parse("When Living Room MotionAware detects motion, turn on Living Room", snapshot: snap)
        XCTAssertEqual(maRule.calls.first?.name, "hue_create_rule")
        XCTAssertEqual(maRule.calls.first?.arguments["trigger_kind"]?.stringValue, "motion_area")
        XCTAssertEqual(maRule.calls.first?.arguments["trigger"]?.stringValue, DemoBridgeClient.livingMotionAreaID)

        // Sensor & MotionAware toggle
        let disableSensor = engine.parse("Disable Hallway Motion", snapshot: snap)
        XCTAssertEqual(disableSensor.calls.first?.name, "hue_set_sensor")
        XCTAssertEqual(disableSensor.calls.first?.arguments["enabled"]?.boolValue, false)

        let disableMA = engine.parse("Disable Living Room MotionAware", snapshot: snap)
        XCTAssertEqual(disableMA.calls.first?.name, "hue_set_motion_area")
        XCTAssertEqual(disableMA.calls.first?.arguments["enabled"]?.boolValue, false)
    }

    @MainActor
    func testMCPServerLifecycleToolsAndSecretRedaction() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("hue-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let settings = SettingsStore(directory: tempDir)
        let demo = DemoBridgeClient()
        demo.start()
        let backend = HeadlessHueToolBackend(client: demo, settings: settings, initialSnapshot: demo.currentSnapshot())
        let server = HueMCPServer(backend: backend)

        // 1. initialize
        let initReply = try XCTUnwrap(await server.handleRequestLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        XCTAssertTrue(initReply.contains(HueMCPServer.protocolVersion))
        XCTAssertTrue(initReply.contains(HueMCPServer.serverName))

        // 2. notifications/initialized -> nil
        let notifReply = await server.handleRequestLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notifReply)

        // 3. ping
        let pingReply = try XCTUnwrap(await server.handleRequestLine(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#))
        XCTAssertTrue(pingReply.contains(#""result":{}"#))

        // 4. tools/list contains all required tools
        let listReply = try XCTUnwrap(await server.handleRequestLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        for requiredTool in [
            "hue_status", "hue_list_rooms", "hue_list_lights", "hue_list_sensors",
            "hue_list_themes", "hue_list_rules", "hue_list_schedules", "hue_get_floorplan",
            "hue_set_light", "hue_set_room", "hue_recall_scene", "hue_apply_theme",
            "hue_all_on", "hue_all_off", "hue_set_sensor", "hue_set_motion_area",
            "hue_create_rule", "hue_toggle_rule", "hue_delete_rule",
        ] {
            XCTAssertTrue(listReply.contains("\"\(requiredTool)\""), "Missing MCP tool \(requiredTool)")
        }

        // 5. tools/call: set light by name, recall scene, apply theme, toggle sensor & motion area, create/toggle/delete rule
        let setLightReply = try XCTUnwrap(await server.handleRequestLine(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"hue_set_light","arguments":{"target":"Desk Lamp","on":true,"bri":55}}}"#
        ))
        XCTAssertTrue(setLightReply.contains(#""isError":false"#))
        XCTAssertEqual(Int((demo.currentSnapshot().light(DemoBridgeClient.deskLampID)?.bri ?? 0).rounded()), 55)

        let allOffReply = try XCTUnwrap(await server.handleRequestLine(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"hue_all_off","arguments":{}}}"#
        ))
        XCTAssertTrue(allOffReply.contains(#""isError":false"#))
        XCTAssertEqual(demo.currentSnapshot().onCount, 0)

        let createRuleReply = try XCTUnwrap(await server.handleRequestLine(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"hue_create_rule","arguments":{"name":"MCP Motion Rule","trigger_kind":"motion","trigger":"Hallway Motion","target_kind":"room","target":"Hallway","action":"on"}}}"#
        ))
        XCTAssertTrue(createRuleReply.contains("MCP Motion Rule"))
        let createdRule = try XCTUnwrap(backend.currentRules.first { $0.name == "MCP Motion Rule" })

        let toggleReply = try XCTUnwrap(await server.handleRequestLine(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"hue_toggle_rule","arguments":{"rule":"MCP Motion Rule","enabled":false}}}"#
        ))
        XCTAssertTrue(toggleReply.contains(#""isError":false"#))
        XCTAssertEqual(backend.currentRules.first { $0.id == createdRule.id }?.enabled, false)

        let deleteReply = try XCTUnwrap(await server.handleRequestLine(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"hue_delete_rule","arguments":{"rule":"MCP Motion Rule"}}}"#
        ))
        XCTAssertTrue(deleteReply.contains(#""isError":false"#))
        XCTAssertNil(backend.currentRules.first { $0.id == createdRule.id })

        // 6. resources/list & resources/read (hue://state) — verify no credential keys ever leak
        let resList = try XCTUnwrap(await server.handleRequestLine(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#))
        XCTAssertTrue(resList.contains("hue://state"))

        let resRead = try XCTUnwrap(await server.handleRequestLine(#"{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"hue://state"}}"#))
        XCTAssertTrue(resRead.contains("Living Room"))
        for secretKey in ["app_key", "appKey", "client_key", "clientKey", "fingerprint"] {
            XCTAssertFalse(resRead.contains(secretKey), "MCP hue://state must never expose \(secretKey)")
        }
    }
}

final class ProAccessPolicyTests: XCTestCase {
    func testProductIDAndAccessModes() {
        XCTAssertEqual(ProAccessPolicy.proProductID, "com.maprisma.huelights.pro")
        XCTAssertEqual(ProAccessPolicy.mode(isProUnlocked: false, isDemoMode: false), .free)
        XCTAssertEqual(ProAccessPolicy.mode(isProUnlocked: false, isDemoMode: true), .demo)
        XCTAssertEqual(ProAccessPolicy.mode(isProUnlocked: true, isDemoMode: false), .pro)
        XCTAssertEqual(ProAccessPolicy.mode(isProUnlocked: true, isDemoMode: true), .pro)
    }

    func testFeatureUnlockMatrixFreeDemoPro() {
        XCTAssertEqual(ProFeature.allCases.count, 7)
        for feature in ProFeature.allCases {
            // Free on a real Hue Bridge -> Pro features locked
            XCTAssertFalse(
                ProAccessPolicy.isUnlocked(feature, isProUnlocked: false, isDemoMode: false),
                "Expected \(feature.rawValue) to be locked in Free mode"
            )
            // Demo Mode -> ALL Pro features unlocked for risk-free evaluation & App Review
            XCTAssertTrue(
                ProAccessPolicy.isUnlocked(feature, isProUnlocked: false, isDemoMode: true),
                "Expected \(feature.rawValue) to be unlocked in Demo mode"
            )
            // Pro unlocked on real Bridge -> ALL Pro features unlocked
            XCTAssertTrue(
                ProAccessPolicy.isUnlocked(feature, isProUnlocked: true, isDemoMode: false),
                "Expected \(feature.rawValue) to be unlocked in Pro mode"
            )
            // Pro unlocked + Demo -> unlocked
            XCTAssertTrue(
                ProAccessPolicy.isUnlocked(feature, isProUnlocked: true, isDemoMode: true),
                "Expected \(feature.rawValue) to be unlocked in Pro + Demo mode"
            )
        }
    }

    func testIsSkinFree() {
        XCTAssertTrue(ProAccessPolicy.isSkinFree("native"))
        XCTAssertTrue(ProAccessPolicy.isSkinFree(""))
        XCTAssertTrue(ProAccessPolicy.isSkinFree("system"))
        XCTAssertTrue(ProAccessPolicy.isSkinFree("  Native  "))
        XCTAssertTrue(ProAccessPolicy.isSkinFree(AppSkin.system))

        for skin in AppSkin.allCases where skin != .system {
            XCTAssertFalse(ProAccessPolicy.isSkinFree(skin), "Skin \(skin.rawValue) should require Pro")
            XCTAssertFalse(ProAccessPolicy.isSkinFree(skin.rawValue), "Skin rawValue \(skin.rawValue) should require Pro")
        }
        XCTAssertFalse(ProAccessPolicy.isSkinFree("synthwave"))
        XCTAssertFalse(ProAccessPolicy.isSkinFree("cozyCabin"))
        XCTAssertFalse(ProAccessPolicy.isSkinFree("retroTerminal"))
        XCTAssertFalse(ProAccessPolicy.isSkinFree("discoLava"))
        XCTAssertFalse(ProAccessPolicy.isSkinFree("minimalZen"))
    }

    func testLastVerifiedProCliHintDefaultFalseAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hue-pro-hint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        XCTAssertFalse(store.lastVerifiedPro())
        try store.setLastVerifiedPro(true)
        XCTAssertTrue(store.lastVerifiedPro())
        try store.setLastVerifiedPro(false)
        XCTAssertFalse(store.lastVerifiedPro())
    }
}

final class MultiProviderTests: XCTestCase {
    func testResourceIDAndLocalHostValidation() {
        XCTAssertTrue(HueColorMath.validResourceID("11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(HueColorMath.validResourceID("wled:abc123:0"))
        XCTAssertTrue(HueColorMath.validResourceID("ha:main:light.kitchen_ceiling"))
        XCTAssertTrue(HueColorMath.validResourceID("dirigera:hub1:room:r-01"))
        XCTAssertFalse(HueColorMath.validResourceID("../etc/passwd"))
        XCTAssertFalse(HueColorMath.validResourceID("ha:main:../escape"))
        XCTAssertEqual(HueColorMath.providerPrefix(of: "11111111-1111-1111-1111-111111111111"), "hue")
        XCTAssertEqual(HueColorMath.providerPrefix(of: "wled:abc:0"), "wled")
        XCTAssertEqual(HueColorMath.providerPrefix(of: "ha:main:light.desk"), "ha")

        XCTAssertTrue(HueColorMath.validLocalHost("192.168.178.42"))
        XCTAssertTrue(HueColorMath.validLocalHost("10.0.0.5"))
        XCTAssertTrue(HueColorMath.validLocalHost("wled-desk.local"))
        XCTAssertFalse(HueColorMath.validLocalHost("8.8.8.8"))
        XCTAssertFalse(HueColorMath.validLocalHost("example.com"))
        XCTAssertFalse(HueColorMath.validLocalHost("127.0.0.1", allowLoopback: false))
        XCTAssertTrue(HueColorMath.validLocalHost("127.0.0.1", allowLoopback: true))
        XCTAssertTrue(HueColorMath.validLocalHost("localhost", allowLoopback: true))
    }

    func testRGBAndHSBColorRoundTrip() {
        let hsb = HueColorMath.rgbToHSB(r: 255, g: 128, b: 0)
        XCTAssertEqual(hsb.hue, 30.1, accuracy: 0.5)
        XCTAssertEqual(hsb.sat, 100.0, accuracy: 0.5)
        XCTAssertEqual(HueColorMath.hsbToHex(hue: 0, sat: 100, bri: 100), "#ff0000")
        XCTAssertEqual(HueColorMath.hsbToHex(hue: 120, sat: 100, bri: 100), "#00ff00")
        XCTAssertEqual(HueColorMath.hsbToHex(hue: 240, sat: 100, bri: 100), "#0000ff")
    }

    func testHomeAssistantParserLightsScenesAndSensors() {
        let conn = ProviderConnection(id: "ha1", kind: .homeAssistant, name: "Home Assistant", host: "192.168.1.10")
        let states: [[String: Any]] = [
            [
                "entity_id": "light.kitchen_strip",
                "state": "on",
                "attributes": [
                    "friendly_name": "Kitchen Strip",
                    "brightness": 204,
                    "rgb_color": [255, 100, 50],
                    "supported_color_modes": ["rgb", "color_temp"],
                    "effect_list": ["Rainbow", "Pulse"],
                    "effect": "Rainbow",
                ],
            ],
            [
                "entity_id": "scene.movie_night",
                "state": "scening",
                "attributes": ["friendly_name": "Movie Night"],
            ],
            [
                "entity_id": "binary_sensor.hall_motion",
                "state": "on",
                "attributes": ["friendly_name": "Hall Motion", "device_class": "motion"],
            ],
        ]
        let result = HomeAssistantParser.parseStates(connection: conn, states: states, entityAreas: ["light.kitchen_strip": "Kitchen"])
        XCTAssertEqual(result.lightCount, 1)
        XCTAssertEqual(result.onCount, 1)
        XCTAssertEqual(result.rooms.first?.name, "Kitchen")
        XCTAssertEqual(result.rooms.first?.provider, "home_assistant")
        XCTAssertEqual(result.rooms.first?.lights.first?.id, "ha:ha1:light.kitchen_strip")
        XCTAssertEqual(result.rooms.first?.lights.first?.color, "#ff6432")
        XCTAssertEqual(result.rooms.first?.scenes.first?.name, "Movie Night")
        XCTAssertEqual(result.sensors.count, 1)
        XCTAssertEqual(result.sensors.first?.kind, "motion")
        XCTAssertTrue(result.sensors.first?.motion == true)
    }

    func testWLEDParserAndStatePayload() {
        let conn = ProviderConnection(id: "w1", kind: .wled, name: "Desk Strip", host: "192.168.1.40", roomName: "Office")
        let json: [String: Any] = [
            "state": [
                "on": true,
                "bri": 128,
                "ps": 2,
                "seg": [["col": [[0, 200, 255]], "fx": 1]],
            ],
            "info": ["name": "Desk WLED", "mac": "aabbccddeeff"],
            "effects": ["Solid", "Blink", "Rainbow"],
        ]
        let presets: [String: Any] = ["1": ["n": "Warm"], "2": ["n": "Cyberpunk"]]
        let res = WLEDParser.parse(connection: conn, json: json, presets: presets)
        XCTAssertEqual(res.lightCount, 1)
        XCTAssertEqual(res.rooms.first?.name, "Office")
        XCTAssertEqual(res.rooms.first?.lights.first?.color, "#00c8ff")
        XCTAssertEqual(res.rooms.first?.lights.first?.effect, "Blink")
        XCTAssertEqual(res.rooms.first?.scenes.count, 2)
        XCTAssertTrue(res.rooms.first?.scenes.first(where: { $0.name == "Cyberpunk" })?.active == true)

        let payload = WLEDParser.buildStatePayload(on: true, bri: 50, mirek: nil, xy: (0.64, 0.33), effect: "Rainbow", effectsList: ["Solid", "Blink", "Rainbow"])
        XCTAssertEqual(payload["on"] as? Bool, true)
        XCTAssertEqual(payload["bri"] as? Int, 128)
    }

    func testWiZCodecPilotAndSetPilot() throws {
        let conn = ProviderConnection(id: "wiz1", kind: .wiz, name: "Floor Lamp", host: "192.168.1.41")
        let res = WiZCodec.parsePilot(connection: conn, json: [
            "result": ["state": true, "dimming": 70, "r": 255, "g": 170, "b": 40, "sceneId": 6, "mac": "112233445566"],
        ])
        XCTAssertEqual(res.lightCount, 1)
        XCTAssertEqual(res.rooms.first?.lights.first?.color, "#ffaa28")
        XCTAssertEqual(res.rooms.first?.lights.first?.bri, 70)
        XCTAssertTrue(res.rooms.first?.scenes.contains(where: { $0.name == "Cozy" && $0.active }) == true)

        let cmd = WiZCodec.encodeSetPilot(on: true, bri: 60, mirek: 300, xy: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: cmd) as? [String: Any])
        XCTAssertEqual(obj["method"] as? String, "setPilot")
    }

    func testLIFXBinaryPacketEncodeAndDecode() throws {
        let getPkt = LIFXCodec.encodeGetColor()
        XCTAssertEqual(getPkt.count, 36)
        let powerPkt = LIFXCodec.encodeSetPower(on: true, durationMs: 300)
        XCTAssertEqual(powerPkt.count, 42)

        // Construct a synthetic LightState (type 107) reply packet (36 + 52 = 88 bytes)
        var reply = Data(count: 88)
        reply[32] = UInt8(LIFXCodec.msgLightState & 0xFF)
        reply[33] = UInt8(LIFXCodec.msgLightState >> 8)
        // hue=0, sat=65535, bri=32768 (~50%), kelvin=3500, power=65535
        reply[38] = 0xFF; reply[39] = 0xFF
        reply[40] = 0x00; reply[41] = 0x80
        reply[42] = UInt8(3500 & 0xFF); reply[43] = UInt8(3500 >> 8)
        reply[46] = 0xFF; reply[47] = 0xFF
        let labelData = Data("Studio Bulb".utf8)
        reply.replaceSubrange(48..<(48 + labelData.count), with: labelData)

        let decoded = try XCTUnwrap(LIFXCodec.decodeLightState(reply))
        XCTAssertTrue(decoded.powerOn)
        XCTAssertEqual(decoded.kelvin, 3500)
        XCTAssertEqual(decoded.label, "Studio Bulb")
        XCTAssertEqual(decoded.brightness, 50.0, accuracy: 0.5)
    }

    func testGoveeNanoleafShellyAndDirigeraParsers() {
        let goveeConn = ProviderConnection(id: "g1", kind: .govee, name: "TV Backlight", host: "192.168.1.42")
        let goveeRes = GoveeCodec.parseStatus(connection: goveeConn, json: [
            "msg": ["data": ["onOff": 1, "brightness": 85, "color": ["r": 120, "g": 40, "b": 255]]],
        ])
        XCTAssertEqual(goveeRes.rooms.first?.lights.first?.color, "#7828ff")
        XCTAssertEqual(GoveeCodec.encodeCommands(on: true, bri: 80, mirek: nil, xy: (0.15, 0.06)).count, 3)

        let nanoConn = ProviderConnection(id: "n1", kind: .nanoleaf, name: "Wall Shapes", host: "192.168.1.43")
        let (nanoRes, sceneMap) = NanoleafParser.parse(connection: nanoConn, json: [
            "name": "Shapes",
            "serialNo": "S123",
            "state": [
                "on": ["value": true],
                "brightness": ["value": 75],
                "hue": ["value": 180],
                "sat": ["value": 80],
                "ct": ["value": 3000],
                "colorMode": "hs",
            ],
            "effects": ["select": "Northern Lights", "effectsList": ["Northern Lights", "Sunset"]],
        ])
        XCTAssertEqual(nanoRes.lightCount, 1)
        XCTAssertEqual(nanoRes.rooms.first?.scenes.count, 2)
        XCTAssertEqual(sceneMap.count, 2)

        let shellyConn = ProviderConnection(id: "s1", kind: .shelly, name: "Hallway Dimmer", host: "192.168.1.44")
        let (shellyRes, meta) = ShellyParser.parseGen2(
            connection: shellyConn,
            info: ["name": "Hall Dimmer", "mac": "AABBCC"],
            status: ["light:0": ["output": true, "brightness": 64.0]]
        )
        XCTAssertEqual(shellyRes.lightCount, 1)
        XCTAssertEqual(meta["shelly:s1:light:0"]?.gen, 2)

        let dirConn = ProviderConnection(id: "d1", kind: .dirigera, name: "IKEA Hub", host: "192.168.1.45")
        let dirRes = DirigeraParser.parse(
            connection: dirConn,
            devices: [
                [
                    "id": "dev-1",
                    "type": "light",
                    "isReachable": true,
                    "room": ["id": "rm-1", "name": "Bedroom"],
                    "attributes": ["customName": "TRÅDFRI Lamp", "isOn": true, "lightLevel": 45, "colorTemperature": 2700],
                    "capabilities": ["canReceive": ["isOn", "lightLevel", "colorTemperature"]],
                ],
                [
                    "id": "sen-1",
                    "type": "sensor",
                    "deviceType": "motionSensor",
                    "isReachable": true,
                    "room": ["id": "rm-1", "name": "Bedroom"],
                    "attributes": ["customName": "VALLHORN", "isDetected": true, "batteryPercentage": 92],
                ],
            ],
            scenes: [["id": "sc-1", "info": ["name": "Good Night"]]]
        )
        XCTAssertEqual(dirRes.lightCount, 1)
        XCTAssertEqual(dirRes.rooms.first?.name, "Bedroom")
        XCTAssertEqual(dirRes.rooms.first?.scenes.first?.name, "Good Night")
        XCTAssertEqual(dirRes.sensors.count, 1)
        XCTAssertTrue(dirRes.sensors.first?.motion == true)
    }

    func testSettingsStoreProvidersPersistenceAndSecrets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hue-providers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        let conns = [
            ProviderConnection(id: "ha1", kind: .homeAssistant, name: "Home Assistant", host: "192.168.1.10"),
            ProviderConnection(id: "wled1", kind: .wled, name: "Desk Strip", host: "192.168.1.40", roomName: "Office"),
        ]
        try store.saveProviders(conns)
        let loaded = store.loadProviders()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].kind, .homeAssistant)
        XCTAssertEqual(loaded[1].roomName, "Office")

        let secrets = InMemoryProviderSecretStore()
        try secrets.saveSecret("top-secret-token", for: "ha1")
        XCTAssertEqual(secrets.loadSecret(for: "ha1"), "top-secret-token")
        try secrets.deleteSecret(for: "ha1")
        XCTAssertNil(secrets.loadSecret(for: "ha1"))
    }
}
