import SwiftUI

/// Вкладка «Музыка»: крупная обложка, метаданные, перемотка и транспорт.
struct MusicTab: View {
    @EnvironmentObject private var state: AppState
    /// Позиция под пальцем, пока тянут полосу (0…1). Иначе — живое время сервиса.
    @State private var scrub: Double?
    @State private var barHovered = false

    private var media: MediaService { state.media }

    private var displayed: Double { scrub ?? media.progress }

    private var displayedElapsed: TimeInterval {
        guard let track = media.track else { return 0 }
        if let scrub, track.duration > 0 { return scrub * track.duration }
        return media.elapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(title: "Музыка") {
                if !media.sourceName.isEmpty, media.track != nil {
                    HStack(spacing: 5) {
                        if let icon = media.sourceIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 13, height: 13)
                        }
                        Text(media.sourceName)
                            .font(.system(size: 10))
                            .hubForeground(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }

            if let track = media.track {
                player(track)
            } else {
                idle
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: — ничего не играет

    /// Заглушка ведёт прямо в Яндекс Музыку: это единственный плеер,
    /// которым пользуются, и лишний повод лезть в Dock тут ни к чему.
    private var idle: some View {
        VStack(spacing: 10) {
            Group {
                if let icon = YandexMusic.appIcon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 26, weight: .light))
                        .hubForeground(.white.opacity(0.35))
                }
            }
            .frame(width: 44, height: 44)
            .opacity(0.9)

            Text(idleText)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .hubForeground(Theme.secondaryText)

            Button(action: openYandex) {
                Text(YandexMusic.openTitle)
                    .font(.system(size: 11, weight: .medium))
                    .hubForeground(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent.opacity(0.85)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idleText: String {
        if !YandexMusic.isInstalled { return "Ничего не играет" }
        return YandexMusic.isRunning
            ? "Яндекс Музыка запущена, но ничего не играет"
            : "Ничего не играет"
    }

    private func openYandex() {
        YandexMusic.open()
        state.collapse(immediate: true)
    }

    // MARK: — плеер

    private func player(_ track: NowPlaying) -> some View {
        HStack(alignment: .top, spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .hubForeground(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 12))
                        .hubForeground(.white.opacity(0.75))
                        .lineLimit(1)
                }
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.system(size: 11))
                        .hubForeground(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                timeline(track)
                transport
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 150)
    }

    private var cover: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                // Обложка приходит с задержкой — вместо серого пятна показываем,
                // кто играет: у Яндекс Музыки это её же иконка.
                ZStack {
                    Color.white.opacity(0.08)
                    if let icon = media.sourceIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .opacity(0.7)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 34, weight: .light))
                            .hubForeground(.white.opacity(0.35))
                    }
                }
            }
        }
        .frame(width: 150, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
        // Обложка ничего не нажимает — и не должна мешать нажимать другим.
        // `aspectRatio(.fill)` растягивает картинку ЗА рамку: кадр 16:9 в квадрате
        // 150×150 вылезает на 58 pt в каждую сторону. `clipShape` прячет это лишь
        // на вид, зона нажатия остаётся во всю ширину картинки — и невидимый край
        // накрывал колонку слева, из-за чего «Полка», «Буфер», «Заготовки»
        // и «Календарь» переставали нажиматься, пока играет широкая обложка.
        .allowsHitTesting(false)
    }

    // MARK: — полоса перемотки

    private func timeline(_ track: NowPlaying) -> some View {
        VStack(spacing: 3) {
            seekBar(track)
            HStack(spacing: 6) {
                Text(Fmt.time(displayedElapsed))
                Spacer(minLength: 0)
                Text(track.duration > 0 ? Fmt.time(track.duration) : "прямой эфир")
            }
            .font(.system(size: 10).monospacedDigit())
            .hubForeground(Theme.secondaryText)
        }
    }

    private func seekBar(_ track: NowPlaying) -> some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let value = min(1, max(0, displayed))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(Theme.accent).frame(width: value * width)
                Circle()
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .offset(x: value * width - 4.5)
                    .opacity(track.duration > 0 && (barHovered || scrub != nil) ? 1 : 0)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { barHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard track.duration > 0 else { return }
                        scrub = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        scrub = nil
                        guard track.duration > 0 else { return }
                        let fraction = min(1, max(0, value.location.x / width))
                        media.seek(to: fraction * track.duration)
                        Haptics.tap()
                    }
            )
        }
        .frame(height: 14)
        .animation(scrub == nil ? Theme.quick : nil, value: barHovered)
    }

    // MARK: — транспорт и подпись

    private var transport: some View {
        HStack(spacing: 14) {
            TransportButton(icon: "backward.fill", size: 15) { media.previous() }
            MediaPlayButton(playing: media.isPlaying) { media.toggle() }
            TransportButton(icon: "forward.fill", size: 15) { media.next() }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: footerIcon)
            Text(footerText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9))
        .hubForeground(.white.opacity(media.backend == .appleScript ? 0.6 : 0.35))
    }

    private var footerIcon: String {
        switch media.backend {
        case .none: return "hourglass"
        case .adapter: return "waveform"
        case .appleScript: return "exclamationmark.triangle"
        }
    }

    /// В AppleScript-режиме предупреждаем честно: запасной путь умеет только
    /// Spotify и «Музыку», а Яндекс Музыку не видит вообще.
    private var footerText: String {
        media.backend == .appleScript
            ? "Запасной режим AppleScript: Яндекс Музыку он не видит"
            : "Источник данных: \(media.backend.label)"
    }
}

/// Крупная круглая кнопка play/pause вкладки.
struct MediaPlayButton: View {
    let playing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(hovering ? 0.22 : 0.14))
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .hubForeground(.white)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
