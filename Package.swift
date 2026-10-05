// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kkuk",
    platforms: [.macOS(.v13)],
    products: [.library(name: "KkukCore", targets: ["KkukCore"])],
    targets: [
        .target(name: "KkukCore", path: "Kkuk/Core")
    ]
)
