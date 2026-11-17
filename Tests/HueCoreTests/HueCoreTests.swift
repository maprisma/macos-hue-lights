import XCTest
@testable import HueCore

private let snapshotLine = """
{"phase":"ok","error":"","bridge":{"ip":"192.168.1.50","name":"Hue","model":"BSB002"},"error_code":"","error_args":[],\
"rooms":[{"id":"cccccccc-1111-1111-1111-111111111111","kind":"room","name":"Living room","grouped_light":"bbbbbbbb-1111-1111-1111-111111111111",\
"on":true,"bri":55.0,"on_count":1,"archetype":"living_room","color":"#ffaa00",\
"lights":[{"id":"11111111-1111-1111-1111-111111111111","name":"Ceiling","on":true,"bri":60.0,"dimmable":true,"color":"#ffaa00","reachable":true},\
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
    func testParsesHelperLine() throws {
        let s = try XCTUnwrap(HueSnapshot.parse(line: snapshotLine))
        XCTAssertEqual(s.phase, "ok")
        XCTAssertTrue(s.isPaired)
        XCTAssertTrue(s.anyLightOn)
        XCTAssertEqual(s.bridge?.text, "Hue · 192.168.1.50")
        XCTAssertEqual(s.rooms.count, 2)
        XCTAssertEqual(s.rooms[0].lights.map(\.name), ["Ceiling", "Arc"])
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

    func testBrightnessStep() {
        XCTAssertEqual(brightnessStep(0), 1)
        XCTAssertEqual(brightnessStep(52), 50)
        XCTAssertEqual(brightnessStep(53), 55)
        XCTAssertEqual(brightnessStep(140), 100)
        XCTAssertEqual(brightnessStep(.nan), 1)
        XCTAssertEqual(cleanedIP("  192.168.1.5 \n"), "192.168.1.5")
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
    func testLanguageRoundTripPrivateModes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hue-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir.appendingPathComponent("hue-lights"))
        XCTAssertEqual(store.language(), "auto")
        try store.setLanguage("nl")
        XCTAssertEqual(store.language(), "nl")
        XCTAssertThrowsError(try store.setLanguage("xx"))
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        let dirMode = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(dirMode?.intValue, 0o700)
    }

    func testDefaultDirectory() {
        XCTAssertEqual(SettingsStore.defaultDirectory(environment: ["HOME": "/Users/a"]).path, "/Users/a/.config/hue-lights")
        XCTAssertEqual(SettingsStore.defaultDirectory(environment: ["HOME": "/Users/a", "XDG_CONFIG_HOME": "/x"]).path, "/x/hue-lights")
        XCTAssertEqual(SettingsStore.defaultDirectory(environment: ["HOME": "/Users/a", "XDG_CONFIG_HOME": "rel"]).path,
                       "/Users/a/.config/hue-lights")
    }
}

final class SupervisorTests: XCTestCase {
    func testEnvironmentPutsHomebrewFirst() {
        let env = HelperSupervisor.environment(base: ["PATH": "/usr/bin:/custom", "HOME": "/h"])
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/custom")
        XCTAssertEqual(env["HOME"], "/h")
        XCTAssertEqual(HelperSupervisor.environment(base: [:])["PATH"], HelperSupervisor.searchPath)
    }

    func testLineBuffer() {
        var buffer = LineBuffer(limit: 32)
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(buffer.append(Data(":2}\n\n".utf8)), ["{\"b\":2}"])
        XCTAssertEqual(buffer.append(Data(String(repeating: "x", count: 40).utf8)), [])
        XCTAssertEqual(buffer.append(Data("ok\n".utf8)), ["ok"])
    }

    /// The real helper end to end: first snapshot arrives, a command goes in, stop() ends it.
    func testRunsTheRealHelper() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("scripts/hue-lights.py")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hue-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        setenv("XDG_CONFIG_HOME", home.path, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }

        let callbacks = DispatchQueue(label: "test.callbacks")
        let supervisor = HelperSupervisor(scriptURL: script, restartDelay: 0.5, callbackQueue: callbacks)
        let first = expectation(description: "first snapshot")
        first.assertForOverFulfill = false
        supervisor.onSnapshot = { snapshot in
            if snapshot.phase == "unpaired" { first.fulfill() }
        }
        supervisor.start()
        wait(for: [first], timeout: 10)
        XCTAssertTrue(supervisor.isRunning)
        supervisor.send(.panelClosed)
        supervisor.stop()
        XCTAssertFalse(supervisor.isRunning)
    }

    func testRestartsAfterExit() {
        let callbacks = DispatchQueue(label: "test.restart")
        // `true` exits at once without output: reported, then started again after the delay.
        let supervisor = HelperSupervisor(scriptURL: URL(fileURLWithPath: "/dev/null"),
                                          launcher: URL(fileURLWithPath: "/usr/bin/env"), python: "true",
                                          restartDelay: 0.2, callbackQueue: callbacks)
        let started = expectation(description: "started twice")
        started.expectedFulfillmentCount = 2
        started.assertForOverFulfill = false
        supervisor.onStarted = { started.fulfill() }
        supervisor.start()
        wait(for: [started], timeout: 5)
        supervisor.stop()
    }
}

final class DebouncerTests: XCTestCase {
    func testThrottleTrailingAndRelease() {
        var clock = Date(timeIntervalSince1970: 0)
        var sent: [(String, Int)] = []
        let queue = DispatchQueue(label: "debounce")
        let debouncer = BrightnessDebouncer(interval: 0.15, queue: queue, now: { clock }) { sent.append(($0, $1)) }
        queue.sync {
            debouncer.update("room:a", 10)               // first value: sent at once
            clock += 0.05
            debouncer.update("room:a", 20)               // within 150 ms: waits (trailing)
            clock += 0.05
            debouncer.update("room:a", 30)
            XCTAssertEqual(debouncer.value(for: "room:a"), 30)
            debouncer.update("light:b", 70)              // another slider is independent
        }
        XCTAssertEqual(sent.map(\.1), [10, 70])
        clock += 0.2
        let trailing = expectation(description: "trailing")
        queue.asyncAfter(deadline: .now() + 0.3) { trailing.fulfill() }
        wait(for: [trailing], timeout: 2)
        queue.sync {
            XCTAssertEqual(sent.map(\.1), [10, 70, 30])  // the latest value, once
            debouncer.finish("room:a")                    // already sent: not again
            XCTAssertNil(debouncer.value(for: "room:a"))
            clock += 0.01
            debouncer.update("light:b", 75)
            debouncer.finish("light:b")                   // release sends the last value at once
        }
        XCTAssertEqual(sent.map(\.1), [10, 70, 30, 75])
        XCTAssertEqual(sent.last?.0, "light:b")
    }
}
