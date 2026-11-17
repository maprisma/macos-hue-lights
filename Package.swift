// swift-tools-version:5.9
// Maprisma Hue Lights for macOS: a SwiftUI menu bar app (MenuBarExtra, window style) on top of
// the same stdlib-only Python bridge helper as the Linux apps (scripts/hue-lights.py).
import PackageDescription

var targets: [Target] = [
    // Foundation only (no AppKit/SwiftUI): the helper protocol, models, translations,
    // the subprocess supervisor and the slider debouncer. Builds and tests on Linux too.
    .target(name: "HueCore", path: "Sources/HueCore"),
    .testTarget(name: "HueCoreTests", dependencies: ["HueCore"], path: "Tests/HueCoreTests"),
]
var products: [Product] = []

#if os(macOS)
// The SwiftUI menu bar app itself (AppKit/SwiftUI exist only on macOS).
targets.append(.executableTarget(
    name: "MaprismaHueLights",
    dependencies: ["HueCore"],
    path: "Sources/MaprismaHueLights"
))
products.append(.executable(name: "MaprismaHueLights", targets: ["MaprismaHueLights"]))
#endif

let package = Package(
    name: "MaprismaHueLights",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
