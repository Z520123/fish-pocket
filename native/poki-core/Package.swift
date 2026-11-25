// swift-tools-version: 5.10
// PokiCore: the phone-side core (MCP, look/do, approvals). No UIKit or SwiftUI;
// iOS-only pieces arrive through the CoreHost protocol.
import PackageDescription

let package = Package(
    name: "PokiCore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "PokiCore", targets: ["PokiCore"])],
    targets: [
        .target(name: "PokiCore"),
    ]
)
