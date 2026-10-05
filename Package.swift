// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kkuk",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Kkuk", targets: ["Kkuk"])],
    targets: [
        .target(name: "KkukCore", path: "Kkuk/Core"),
        .executableTarget(name: "Kkuk", dependencies: ["KkukCore"], path: "Kkuk", exclude: ["Core", "Resources"])
    ]
)
