// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Одни и те же исходники собираются под две минимальные системы.
// `MACOS11=1 ./Scripts/dmg.sh` даёт сборку для Big Sur, без переменной — обычную.
//
// Зачем вообще две: на macOS 11–13 часть API недоступна, и код обходит это
// через `if #available`. Держать ради этого отдельную копию проекта — верный
// способ развести их правками, поэтому цель выбирается переменной окружения.
let minimumMacOS: SupportedPlatform = ProcessInfo.processInfo.environment["MACOS11"] == "1"
    ? .macOS(.v11)
    : .macOS(.v14)

let package = Package(
    name: "NotchHub",
    platforms: [minimumMacOS],
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
