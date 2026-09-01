import AppKit
import Carbon.HIToolbox

/// Глобальная горячая клавиша ⌃⌥Пробел: раскрывает и закрывает панель без мыши.
///
/// Carbon `RegisterEventHotKey`, а не `NSEvent` с монитором клавиатуры: монитору
/// нужны права Универсального доступа, а их у сборки с ad-hoc подписью система
/// отзывает после каждой пересборки — приложение считается новым. Carbon-хоткею
/// разрешения не нужны вовсе.
@MainActor final class HotKey {
    static let shared = HotKey()

    /// Комбинация занята другим приложением — показываем это в настройках.
    private(set) var isBlocked = false

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature = OSType(0x4E48_4B31) // 'NHK1'

    private init() {}

    var isRegistered: Bool { ref != nil }

    func apply(enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard ref == nil else { return }
        installHandlerIfNeeded()

        let id = EventHotKeyID(signature: signature, id: 1)
        var newRef: EventHotKeyRef?
        // kVK_Space (49) с Control и Option.
        let status = RegisterEventHotKey(UInt32(kVK_Space),
                                         UInt32(controlKey | optionKey),
                                         id,
                                         GetApplicationEventTarget(),
                                         0,
                                         &newRef)
        if status == noErr, let newRef {
            ref = newRef
            isBlocked = false
            Log.app.info("горячая клавиша ⌃⌥Пробел зарегистрирована")
        } else {
            // eventHotKeyExistsErr (-9878) — комбинацию занял кто-то другой.
            isBlocked = true
            Log.app.error("горячая клавиша недоступна, код \(status, privacy: .public)")
        }
    }

    private func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        isBlocked = false
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppState.shared.toggleExpanded() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
