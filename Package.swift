// swift-tools-version:5.10
import PackageDescription

let apps = ["Jot", "Meridian", "Hush", "Plain", "Tempo"]

let package = Package(
    name: "macapps",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Kit", linkerSettings: [.linkedFramework("Carbon")]),
        .executableTarget(name: "IconGen", path: "Tools/IconGen"),
        .testTarget(name: "KitTests", dependencies: ["Kit"]),
    ] + apps.map { .executableTarget(name: $0, dependencies: ["Kit"]) }
)
