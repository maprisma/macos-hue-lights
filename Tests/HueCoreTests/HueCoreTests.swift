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

        // Echo suppression for B within 1.5s
        XCTAssertTrue(engine.isEcho(kind: "light", id: b))
        // Cooldown prevents re-firing within 2.0s
        now += 1.0
        XCTAssertTrue(engine.evaluateChange(kind: "light", id: a, isOn: false, snapshot: snap).isEmpty)

        // After 2.5s cooldown & echo cleared, mirrorOff triggers OFF on B
        now += 2.0
        let offActions = engine.evaluateChange(kind: "light", id: a, isOn: false, snapshot: snap)
        XCTAssertEqual(offActions.count, 1)
        XCTAssertEqual(offActions[0].on, false)
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
