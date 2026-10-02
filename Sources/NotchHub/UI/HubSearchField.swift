import AppKit
import SwiftUI

/// Search with deterministic focus and list navigation, including macOS 11.
struct HubSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Поиск"
    var autofocus = false
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.textColor = .white
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        guard autofocus, !context.coordinator.focusRequested else { return }
        context.coordinator.focusRequested = true
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeKey()
            window.makeFirstResponder(field)
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HubSearchField
        var focusRequested = false
        init(_ parent: HubSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): AppState.shared.collapse(immediate: true)
            default: return false
            }
            return true
        }
    }
}
