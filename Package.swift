// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cool91",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSMC", path: "Sources/CSMC"),
        .target(name: "Cool91Core", dependencies: ["CSMC"], path: "Sources/Cool91Core",
                linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "cool91", dependencies: ["Cool91Core"], path: "Sources/cool91"),
        .executableTarget(name: "cool91-panel", dependencies: ["Cool91Core"], path: "Sources/cool91-panel"),
    ]
)
