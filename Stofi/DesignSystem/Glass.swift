import SwiftUI

extension View {
    /// Liquid Glass for small, floating UI: cards, overlays, bars. Not for large content areas.
    /// Centralised here so the look can be changed (or a fallback added) in one place.
    func stofiGlass(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// A padded glass card with an optional title.
struct GlassCard<Content: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stofiGlass()
    }
}

extension UInt64 {
    /// File-style byte count, e.g. "12.3 GB", localised.
    var formattedBytes: String {
        Int64(clamping: self).formatted(.byteCount(style: .file))
    }
}

extension Int {
    var formattedCount: String { formatted(.number) }
}
