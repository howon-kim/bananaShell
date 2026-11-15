// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "bananaShell", platforms: [.macOS(.v13)], dependencies: [
    .package(path: "Vendor/BananaZstd"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "be5c0a8b2ce3692ffaad1c3460720dbc16a5bf1f"),
    .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
], targets: [.executableTarget(name: "bananaShell", dependencies: ["SwiftTerm", "BananaZstd", .product(name: "Sparkle", package: "Sparkle")], path: "Sources", resources: [.process("Fonts"), .copy("PromptSupport"), .copy("ProgramLogos")])])
