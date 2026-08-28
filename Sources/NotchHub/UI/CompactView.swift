import SwiftUI

/// Компактная карточка под чёлкой: обложка, трек, прогресс, транспорт.
struct CompactView: View {
    @EnvironmentObject private var state: AppState

    private var media: MediaService { state.media }

    var body: some View {
        HStack(spacing: 10) {
            artwork
            if let track = media.track {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    ProgressLine(value: media.progress)
                        .frame(height: 2)
                        .padding(.top, 2)
                }
                transport
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NotchHub")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(state.shelf.items.isEmpty ? "Ничего не играет" : "На полке: \(state.shelf.items.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artwork: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.10)
                    Image(systemName: media.track == nil ? "sparkles" : "music.note")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var transport: some View {
        HStack(spacing: 10) {
            TransportButton(icon: "backward.fill", size: 11) { media.previous() }
            TransportButton(icon: media.isPlaying ? "pause.fill" : "play.fill", size: 13) { media.toggle() }
            TransportButton(icon: "forward.fill", size: 11) { media.next() }
        }
    }
}

struct TransportButton: View {
    let icon: String
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
                .frame(width: size + 12, height: size + 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ProgressLine: View {
    /// 0…1
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
    }
}
