import AnalysisKit
import SwiftUI

/// Asks what the Mac is used for. The answer selects the quickscan profiles; it can be changed any time
/// via Scan → Change Activities….
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Set<String> = []

    private var profiles: ProfileSettings { model.profiles }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BrandMark(size: 26)
                    Text(verbatim: "Stofi – Storage Fighter")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                Text("What do you use your Mac for?")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Choose one or more activities. Stofi then offers a quickscan that checks exactly the places that typically fill up for them, within seconds. Nothing is removed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(profiles.available) { profile in
                    ProfileTile(profile: profile, isSelected: selection.contains(profile.id)) {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { toggle(profile.id) }
                    }
                }
            }

            HStack {
                Button("Skip") { profiles.skip() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { profiles.save(selection) }
                    .disabled(selection.isEmpty)
                Button("Save and Start Quickscan") {
                    profiles.save(selection)
                    model.quickscan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || model.isScanning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720)
        .onAppear { selection = profiles.selectedIDs }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

private struct ProfileTile: View {
    let profile: ActivityProfile
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: profile.symbol)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: profile.title.resolved()).font(.headline)
                    Text(verbatim: profile.summary.resolved())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                // Shape changes with the state, so selection does not depend on colour.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .stofiGlass(cornerRadius: 14, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
