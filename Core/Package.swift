// swift-tools-version:5.9
import PackageDescription

// Core of the unified on-device agent (WDA-only): the WDA observation, target selection, tap/typing gates and
// cross-app steps (Sources/UnifiedAgentCore/WDA), the upstream app's OpenAI-compatible model client (copied
// unchanged from ios/IPhoneAgent, MIT, LICENSE.upstream-MIT; see VENDORED.md), the experimental ChatGPT plan
// client (Sources/UnifiedAgentCore/ChatGPT) and the element-tree task agent (Sources/UnifiedAgentCore/Agent).
// Swift 5 mode like the upstream app, so the copied files compile unchanged.
let package = Package(
    name: "UnifiedAgentCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "UnifiedAgentCore", targets: ["UnifiedAgentCore"])],
    targets: [
        .target(name: "UnifiedAgentCore"),
        .testTarget(name: "UnifiedAgentCoreTests", dependencies: ["UnifiedAgentCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
