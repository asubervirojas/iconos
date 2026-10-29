// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Iconos",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Iconos", path: "Sources/Iconos"),
    ]
)
