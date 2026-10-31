// swift-tools-version:5.10
import Foundation
import PackageDescription

// Every folder in Sources/ other than Kit is an app. Adding an app needs no edit here.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let apps = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources").path)) ?? [])
    .filter { $0 != "Kit" && !$0.hasPrefix(".") }
    .sorted()

let package = Package(
    name: "macapps",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Kit", linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "KitTests", dependencies: ["Kit"]),
    ] + apps.map { .executableTarget(name: $0, dependencies: ["Kit"]) }
)
