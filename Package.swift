// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cool91",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CSMC", path: "Sources/CSMC"),
        .executableTarget(
            name: "cool91",
            dependencies: ["CSMC"],
            path: "Sources/cool91",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
