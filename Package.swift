// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CiaobotMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CiaobotMac", targets: ["CiaobotMac"])
    ],
    targets: [
        // The face and app-icon artwork ship with the client. It is
        // deliberately a package resource so a debug build and the
        // hand-assembled release .app do not depend on the Ciaobot engine
        // checkout at runtime.
        .executableTarget(
            name: "CiaobotMac",
            exclude: ["Artwork"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CiaobotMacTests",
            dependencies: ["CiaobotMac"]
        ),
    ]
)
