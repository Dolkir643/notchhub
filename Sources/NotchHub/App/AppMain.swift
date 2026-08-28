import AppKit

// Приложение-агент: без иконки в Dock, вся жизнь — в чёлке.
@main
enum NotchHubMain {
    @MainActor static var delegate: AppDelegate?

    @MainActor static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
