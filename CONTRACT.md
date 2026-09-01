# NotchHub — контракт модулей

Каркас (окно-чёлка, морф, вкладки) готов и работает. Каждый модуль заменяет
свои файлы-стабы реальной реализацией, **не трогая ничего чужого**.

## Железные правила

1. **Файлы модуля — только свои.** Список владения ниже. Всё остальное — read-only.
   Особенно нельзя менять: `Package.swift`, `Sources/NotchHub/App/*`,
   `Sources/NotchHub/Window/*`, `UI/RootView.swift`, `UI/ExpandedView.swift`,
   `UI/Theme.swift`, `UI/VisualEffectView.swift`, `Support/*`, `Resources/Info.plist`,
   `Scripts/*`, `CONTRACT.md`.
2. **Публичный API сервиса нельзя сужать.** Имена, сигнатуры и типы из стаба
   обязаны сохраниться — на них опирается каркас. Добавлять новое можно.
3. Новые файлы модуля создавать можно, но с префиксом своей темы
   (`Media*`, `Shelf*`, `Clip*`, `Snippet*`, `Calendar*`, `Translate*`).
4. **Настройки уже есть**, новые ключи не добавлять: `Settings.shared` содержит
   `launchAtLogin`, `shelfRetentionDays`, `autoScreenshots`, `clipboardLimit`,
   `clipboardEnabled`, `hoverOpenDelay`, `hapticsEnabled`, `builtinScreenOnly`,
   `openOnHover`.
5. Весь UI и все строки — **по-русски**. Тексты короткие: панель узкая
   (контент ≈ 574×248 pt после колонки вкладок и отступов).
6. Всё в главном акторе: сервисы — `@MainActor final class … : ObservableObject`.
   Фоновую работу выносить в `Task.detached` / `DispatchQueue`, а результат
   возвращать через `await MainActor.run` или `Task { @MainActor in }`.
7. Язык Swift — режим 5 (`swiftLanguageMode(.v5)`), но код должен быть
   без ошибок и без новых предупреждений.

## Владение файлами

| Модуль      | Файлы |
|-------------|-------|
| music       | `Services/MediaService.swift`, `UI/Tabs/MusicTab.swift`, `UI/MediaControls.swift`, новые `Services/Media*.swift` |
| shelf       | `Services/ShelfService.swift`, `UI/Tabs/ShelfTab.swift`, новые `Services/Shelf*.swift`, `UI/Shelf*.swift` |
| clipboard   | `Services/ClipboardService.swift`, `UI/Tabs/ClipboardTab.swift` |
| snippets    | `Services/SnippetStore.swift`, `UI/Tabs/SnippetsTab.swift` |
| calendar    | `Services/CalendarService.swift`, `UI/Tabs/CalendarTab.swift` |
| translate   | `Services/TranslateService.swift`, `UI/Tabs/TranslateTab.swift` |
| settings    | `UI/Tabs/SettingsTab.swift` |

## Что даёт каркас

```swift
// Глобальное состояние (@EnvironmentObject у всех вкладок):
state.media / state.shelf / state.clipboard / state.snippets
state.calendarService / state.translate / state.settings
state.selectedTab            // NotchTab
state.isExpanded             // панель раскрыта
state.expand(to: .shelf)     // раскрыть на вкладке
state.collapse(immediate:)   // схлопнуть
state.flash("Скопировано")   // всплывающее подтверждение на 1,1 с

// Оформление (UI/Theme.swift):
Theme.panelWidth = 640, Theme.panelHeight = 268, Theme.sidebarWidth = 52
Theme.accent, Theme.panelFill, Theme.cardFill, Theme.cardStroke, Theme.secondaryText
Theme.openSpring / closeSpring / quick        // пружины
.hubCard(12)                                  // модификатор карточки
TabHeader("Заголовок") { …trailing… }         // шапка вкладки
EmptyHint(icon: "tray", text: "Пусто")        // пустое состояние
VisualEffectView(material: .hudWindow)        // размытие

// Форматирование (Support/Formatters.swift):
Fmt.time(_:) Fmt.size(_:) Fmt.dayLong(_:) Fmt.hm(_:)
Fmt.eventSubtitle(start:end:allDay:) Fmt.relative(_:)

// Пути (Support/Log.swift):
AppPaths.root / AppPaths.shelf / AppPaths.shelfIndex / AppPaths.snippets

// Логи: Log.media / Log.shelf / Log.clipboard / Log.snippets / Log.calendar / Log.translate
// Хаптик: Haptics.tap() / Haptics.level()
```

## Ресурсы адаптера MediaRemote в собранном .app

```
NotchHub.app/Contents/Frameworks/MediaRemoteAdapter.framework
NotchHub.app/Contents/Resources/mediaremote-adapter.pl
NotchHub.app/Contents/Resources/MediaRemoteAdapterTestClient
```
Исходник адаптера лежит в `Vendor/mediaremote-adapter`, сборку делает
`Scripts/build.sh` (cmake). При запуске не из бандла искать их в
`<repo>/build/adapter-14.0` (либо `adapter-11.0` — по минимальной системе
сборки) и `<repo>/Vendor/mediaremote-adapter/bin`.

## Как собирать и проверять

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select смотрит на CLT
swift build                    # быстрый прогон компилятора
./Scripts/build.sh             # полный .app с адаптером и подписью
./Scripts/run.sh               # пересобрать и перезапустить
```

Машина автора — Intel-мак **без выреза**, рабочий путь — псевдо-чёлка. Подписных сертификатов нет, подпись ad-hoc: доступы TCC
(календарь, Automation) придётся выдавать заново после пересборки.
