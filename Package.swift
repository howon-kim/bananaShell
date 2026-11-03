// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "bananaShell", platforms: [.macOS(.v13)], dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "be5c0a8b2ce3692ffaad1c3460720dbc16a5bf1f")
], targets: [.executableTarget(name: "bananaShell", dependencies: ["SwiftTerm"], path: "Sources", resources: [.process("Fonts"), .copy("PromptSupport")])])
