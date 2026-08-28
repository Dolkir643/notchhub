// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchHub",
            path: "Sources/NotchHub",
            swiftSettings: [
                // Ядро осознанно живёт в @MainActor-мире AppKit/SwiftUI:
                // строгий режим Swift 6 здесь даёт только шум.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
