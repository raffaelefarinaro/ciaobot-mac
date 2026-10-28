// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CiaobotMac", platforms: [.macOS(.v13)], products: [.executable(name: "CiaobotMac", targets: ["CiaobotMac"])], targets: [.executableTarget(name: "CiaobotMac"), .testTarget(name: "CiaobotMacTests", dependencies: ["CiaobotMac"])])
