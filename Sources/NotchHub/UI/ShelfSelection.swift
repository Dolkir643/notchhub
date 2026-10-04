import AppKit
import SwiftUI

enum ShelfPage: String, CaseIterable, Identifiable {
    case saved, downloads

    var id: Self { self }
    var title: String { self == .saved ? "На полке" : "Загрузки" }
}

/// Монитор читает живое состояние, а не снимок View на момент появления.
/// Каждая панель имеет своё выделение и принимает клавиши только своего окна.
@MainActor final class ShelfSelection: ObservableObject {
    @Published private(set) var ids: Set<UUID> = []
    @Published var page: ShelfPage = .saved
    private(set) var anchor: UUID?
    weak var window: NSWindow?
    private var monitor: Any?

    func select(_ id: UUID, orderedIDs: [UUID], modifiers: NSEvent.ModifierFlags = [],
                preservingGroup: Bool = false) {
        prune(to: orderedIDs)
        guard orderedIDs.contains(id) else { return }
        // Drag и правый клик по выделенному файлу сохраняют всю группу.
        if preservingGroup, ids.contains(id) { return }
        if modifiers.contains(.shift), let anchor,
           let start = orderedIDs.firstIndex(of: anchor),
           let end = orderedIDs.firstIndex(of: id) {
            let range = Set(orderedIDs[min(start, end)...max(start, end)])
            ids = modifiers.contains(.command) ? ids.union(range) : range
        } else if modifiers.contains(.command) {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }

    func selectAll(_ orderedIDs: [UUID]) {
        ids = Set(orderedIDs)
        if anchor.map({ ids.contains($0) }) != true { anchor = orderedIDs.first }
    }

    func prune(to orderedIDs: [UUID]) {
        let available = Set(orderedIDs)
        ids.formIntersection(available)
        if let anchor, !available.contains(anchor) {
            self.anchor = orderedIDs.first(where: { ids.contains($0) })
        }
    }

    func keepMonitor(_ make: () -> Any?) {
        guard monitor == nil else { return }
        monitor = make()
    }

    func dropMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Невидимый мост нужен и при пустой полке: ⌘A нельзя привязывать к первой карточке.
struct ShelfWindowReader: NSViewRepresentable {
    let selection: ShelfSelection

    func makeNSView(context: Context) -> ShelfWindowReaderView {
        let view = ShelfWindowReaderView()
        view.selection = selection
        return view
    }

    func updateNSView(_ view: ShelfWindowReaderView, context: Context) {
        view.selection = selection
        selection.window = view.window
    }
}

final class ShelfWindowReaderView: NSView {
    weak var selection: ShelfSelection?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selection?.window = window
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
