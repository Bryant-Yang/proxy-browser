// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ProxyBrowser",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [.executableTarget(name: "ProxyBrowser", dependencies: ["Yams"]),
              .testTarget(name: "ProxyBrowserTests", dependencies: ["ProxyBrowser", "Yams"])],
    swiftLanguageVersions: [.v5]
)
