import AppKit
import CoreGraphics

/// Геометрия чёлки конкретного экрана.
struct NotchGeometry: Equatable {
    /// Размер физической (или нарисованной) чёлки.
    var size: CGSize
    /// Есть ли настоящий вырез камеры.
    var isRealNotch: Bool
    /// Встроенный ли это дисплей.
    var isBuiltin: Bool
    /// Полный frame экрана в координатах AppKit.
    var screenFrame: CGRect

    /// Ширина «плеч» рядом с чёлкой (для псевдо-чёлки — вся строка меню).
    var menuBarHeight: CGFloat
}

enum ScreenGeometry {
    /// Небольшой запас по бокам, чтобы наша форма перекрывала физический вырез
    /// и не оставляла светлых щелей на краях.
    static let widthPadding: CGFloat = 4

    /// Ширина псевдо-чёлки на экранах без выреза.
    static let pseudoNotchWidth: CGFloat = 200

    /// Минимальная высота чёлки, ниже которой карточка выглядит сплющенной.
    static let minNotchHeight: CGFloat = 24

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    static func isBuiltin(_ screen: NSScreen) -> Bool {
        guard let id = displayID(of: screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Высота строки меню на данном экране.
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let diff = screen.frame.maxY - screen.visibleFrame.maxY
        if diff > 1 { return diff }
        return max(NSStatusBar.system.thickness, 24)
    }

    static func geometry(of screen: NSScreen) -> NotchGeometry {
        let menuBar = menuBarHeight(of: screen)
        let builtin = isBuiltin(screen)

        // `safeAreaInsets` и auxiliary-области пришли в macOS 12. На Big Sur их
        // отсутствие ничего не отнимает: вырез появился только у MacBook Pro 2021,
        // а те с завода идут не ниже Monterey — значит, чёлки там физически нет
        // и путь всегда один, псевдо-чёлка ниже.
        if #available(macOS 12.0, *) {
            let safeTop = screen.safeAreaInsets.top

            if safeTop > 0,
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                // Настоящая чёлка: ширина = экран минус два «плеча» рядом с вырезом.
                let width = screen.frame.width - left.width - right.width + widthPadding
                let height = max(safeTop, minNotchHeight)
                return NotchGeometry(size: CGSize(width: width, height: height),
                                     isRealNotch: true,
                                     isBuiltin: builtin,
                                     screenFrame: screen.frame,
                                     menuBarHeight: menuBar)
            }

            if safeTop > 0 {
                // Чёлка есть, но auxiliary-области недоступны — считаем по безопасной зоне.
                return NotchGeometry(size: CGSize(width: pseudoNotchWidth, height: max(safeTop, minNotchHeight)),
                                     isRealNotch: true,
                                     isBuiltin: builtin,
                                     screenFrame: screen.frame,
                                     menuBarHeight: menuBar)
            }
        }

        // Экран без выреза — рисуем псевдо-чёлку высотой в строку меню.
        return NotchGeometry(size: CGSize(width: pseudoNotchWidth, height: max(menuBar, minNotchHeight)),
                             isRealNotch: false,
                             isBuiltin: builtin,
                             screenFrame: screen.frame,
                             menuBarHeight: menuBar)
    }

    /// Экраны, на которых должен жить хаб.
    @MainActor static func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        if Settings.shared.builtinScreenOnly {
            let builtin = screens.filter(isBuiltin)
            return builtin.isEmpty ? [screens[0]] : builtin
        }
        return screens
    }
}
