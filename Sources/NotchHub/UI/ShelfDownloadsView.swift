import AppKit
import SwiftUI

/// Последние оригиналы в выбранной папке; «На полку» сохраняет независимую копию.
struct ShelfDownloadsView: View {
    @ObservedObject var downloads: ShelfDownloadsService
    @ObservedObject var shelf: ShelfService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let folder = downloads.folderURL {
                HStack(spacing: 8) {
                    Button(action: downloads.chooseFolder) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .help(folder.path)
                    Spacer(minLength: 0)
                    Button(action: downloads.refresh) { Image(systemName: "arrow.clockwise") }
                        .help("Обновить список")
                    Button("Отключить", action: downloads.forgetFolder)
                        .help("Забыть выбранную папку; файлы сохранятся")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .hubForeground(Theme.secondaryText)
            }
            if let error = downloads.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .hubForeground(.orange)
                    .lineLimit(2)
            }
            if downloads.folderURL == nil {
                chooseFolderHint
            } else if downloads.items.isEmpty {
                EmptyHint(icon: "arrow.down.doc",
                          text: "Здесь появятся последние файлы.\nВременные загрузки скрыты.")
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        ForEach(downloads.items) { item in row(item) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var chooseFolderHint: some View {
        VStack(spacing: 8) {
            Text("Выберите папку загрузок.\nФайлы сохраняются на полке по кнопке.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .hubForeground(Theme.secondaryText)
            Button("Выбрать папку", action: downloads.chooseFolder)
                .font(.system(size: 11))
            if downloads.hasFolderSelection {
                HStack(spacing: 12) {
                    Button("Повторить", action: downloads.refresh)
                    Button("Отключить", action: downloads.forgetFolder)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .hubForeground(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: ShelfDownload) -> some View {
        HStack(spacing: 8) {
            fileLabel(item)
            Button { downloads.reveal(item) } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .hubForeground(Theme.secondaryText)
                    .frame(width: 20, height: 26)
            }
            .buttonStyle(.plain)
            .help("Показать в Finder")
            Button {
                Task {
                    if await downloads.save(item, on: shelf) {
                        AppState.shared.flash("Файл на полке")
                    }
                }
            } label: {
                Text(downloads.saving.contains(item.id) ? "Сохраняем…" : "На полку")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 72, height: 24)
                    .hubForeground(item.isReady ? Theme.accent : Theme.secondaryText)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(!item.isReady || downloads.saving.contains(item.id))
            .help("Сохранить независимую копию файла на полке")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .hubCard(8)
    }

    private func fileLabel(_ item: ShelfDownload) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc")
                .font(.system(size: 18))
                .hubForeground(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .hubForeground(.white.opacity(0.9))
                Text(item.isReady ? "\(Fmt.size(item.size)) · \(Fmt.relative(item.modified))"
                                 : "Проверяем файл…")
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .hubForeground(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(dragArea(item))
        .help(item.isReady ? "Перетащите оригинал в другую программу" : "Ждём, пока файл перестанет меняться")
    }

    @ViewBuilder private func dragArea(_ item: ShelfDownload) -> some View {
        if item.isReady {
            let access = downloads.transferAccess
            ShelfDragArea(url: item.url,
                          preview: NSWorkspace.shared.icon(forFile: item.url.path),
                          deleteCornerActive: false,
                          onHover: { _ in },
                          onClick: {},
                          onOpen: { NSWorkspace.shared.open(item.url) },
                          onReveal: { downloads.reveal(item) },
                          onDelete: {},
                          files: {
                              withExtendedLifetime(access) {
                                  [ShelfDragFile(url: item.url, preview: nil)]
                              }
                          },
                          canDelete: false)
        }
    }
}
