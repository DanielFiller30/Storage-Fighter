import SwiftUI

/// Colours of the app icon, used sparingly: the accent colour (asset “AccentColor”) for controls,
/// and the full set only in the small brand mark.
enum Brand {
    static let deepBlue = Color(red: 0.07, green: 0.16, blue: 0.42)
    static let petrol = Color(red: 0.05, green: 0.47, blue: 0.62)
    /// Light turquoise: too little contrast for text or controls, decoration only.
    static let turquoise = Color(red: 0.18, green: 0.78, blue: 0.72)
    static let boltYellow = Color(red: 1.0, green: 0.80, blue: 0.30)
}

/// The icon's motif in small: storage ring with a lightning bolt. Decorative, hidden from VoiceOver.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Brand.deepBlue, Brand.petrol, Brand.turquoise],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: size * 0.09)
                .padding(size * 0.2)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(size * 0.2)
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.32, weight: .bold))
                .foregroundStyle(Brand.boltYellow)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
