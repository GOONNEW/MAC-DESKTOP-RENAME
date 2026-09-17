// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopNamer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DesktopNamer",
            path: "Sources/DesktopNamer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
