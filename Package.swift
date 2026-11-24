// swift-tools-version:5.9
// Maprisma Hue Lights for macOS: a 100% pure-Swift, App Sandbox-compliant SwiftUI menu bar
// & detachable window app talking directly to the Philips Hue Bridge CLIP v2 HTTPS API.
import PackageDescription

var targets: [Target] = [
    // Core Hue models, CLIP v2 parser, SSE parser, rule engine, demo bridge, settings & native client.
    .target(name: "HueCore", path: "Sources/HueCore"),
    .testTarget(name: "HueCoreTests", dependencies: ["HueCore"], path: "Tests/HueCoreTests"),
]
var products: [Product] = []

#if os(macOS)
// The SwiftUI menu bar & window app itself (AppKit/SwiftUI/ServiceManagement exist only on macOS).
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
