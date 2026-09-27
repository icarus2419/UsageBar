// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageBattery",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UsageBattery", targets: ["UsageBattery"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "UsageBattery", dependencies: ["UsageCore"]),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "UsageBatteryTests", dependencies: ["UsageBattery", "UsageCore"]),
    ]
)
