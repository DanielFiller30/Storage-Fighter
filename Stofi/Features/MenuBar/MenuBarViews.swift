import AnalysisKit
import AppKit
import Charts
import ScannerKit
import SwiftUI

/// Symbol (and optionally the free space) in the menu bar. Starts and owns the monitoring task.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.menuBarStatus
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(level: status.level, usedFraction: 1 - (status.volume?.availableFraction ?? 0)))
            if model.settings.showsFreeSpaceInMenuBar, let volume = status.volume {
                Text(volume.usableBytes.formatted(.byteCount(style: .file, allowedUnits: [.gb, .tb], spellsOutZero: false)))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityText)
        // SwiftUI may create this label even while the item is not inserted, so the monitoring is tied to
        // the setting itself: off means no task, switching off cancels it.
        .task(id: model.settings.showsMenuBarExtra) {
            guard model.settings.showsMenuBarExtra else { return }
            AppDelegate.openMainWindow = { openWindow(id: StofiApp.mainWindowID) }
            await status.monitor(settings: model.settings)
        }
    }
}

extension MenuBarStatus {
    var levelTitle: LocalizedStringResource {
        switch level {
        case .normal: "Enough space"
        case .low: "Space is getting low"
        case .critical: "Almost full"
        }
    }

    var accessibilityText: String {
        guard let volume else { return String(localized: "Stofi") }
        return String(localized: "Stofi: \(volume.usableBytes.formattedBytes) available, \(String(localized: levelTitle))")
    }
}

/// Template image (adapts to light and dark menu bars): a ring filled by the used share.
/// The shape changes with the level — plain ring, ring with “!”, filled disc with “!” — so the status
/// does not depend on colour.
enum MenuBarIcon {
    static func image(level: CapacityLevel, usedFraction: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ring = NSBezierPath(ovalIn: inset)
            ring.lineWidth = 1.5
            switch level {
            case .critical:
                ring.fill()
            case .normal, .low:
                ring.stroke()
                // Pie slice for the used share, starting at 12 o'clock, clockwise.
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let slice = NSBezierPath()
                slice.move(to: center)
                slice.appendArc(withCenter: center, radius: inset.width / 2 - 2.5, startAngle: 90,
                                endAngle: 90 - 360 * min(max(usedFraction, 0), 1), clockwise: true)
                slice.close()
                if level == .normal { slice.fill() }
            }
            if level != .normal {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .heavy),
                    .foregroundColor: level == .critical ? NSColor.clear : NSColor.black,
                ]
                let mark = NSAttributedString(string: "!", attributes: attributes)
                let markSize = mark.size()
                let origin = NSPoint(x: rect.midX - markSize.width / 2, y: rect.midY - markSize.height / 2)
                if level == .critical {
                    // Cut the mark out of the filled disc.
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    NSAttributedString(string: "!", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .heavy),
                                                                .foregroundColor: NSColor.black]).draw(at: origin)
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                } else {
                    mark.draw(at: origin)
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The compact popover. It shows numbers and opens the app; it offers no clean-up action.
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let status = model.menuBarStatus
        VStack(alignment: .leading, spacing: 14) {
            if let volume = status.volume {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text(verbatim: volume.name).font(.headline)
                    } icon: {
                        Image(nsImage: MenuBarIcon.image(level: status.level, usedFraction: 1 - volume.availableFraction))
                    }
                    Spacer()
                    Text(status.levelTitle)
                        .font(.callout.bold())
                        .foregroundStyle(status.level == .normal ? Color.secondary : (status.level == .low ? .orange : .red))
                }
                ProgressView(value: 1 - volume.availableFraction)
                    .tint(status.level == .normal ? .accentColor : (status.level == .low ? .orange : .red))
                    .accessibilityLabel("Used share")
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Available")
                        Text(volume.usableBytes.formattedBytes).bold().monospacedDigit()
                    }
                    GridRow {
                        Text("Used")
                        Text(volume.usedBytes.formattedBytes).monospacedDigit()
                    }
                    GridRow {
                        Text("Removable (estimate)")
                        Text(volume.purgeableBytes.formattedBytes).monospacedDigit()
                    }
                }
                .font(.callout)
            } else {
                Text("Capacity unavailable").foregroundStyle(.secondary)
            }

            Divider()
            categories

            Divider()
            HStack {
                Button("Open Stofi") { openMain() }
                Button("Analyse Again") {
                    openMain()
                    model.analyzeFromMenuBar()
                }
                .disabled(model.isScanning)
                Spacer()
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.menuBarStatus.refresh(settings: model.settings) }
    }

    @ViewBuilder
    private var categories: some View {
        if let summary = model.lastSummary, !summary.categories.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Categories").font(.subheadline.bold())
                    Spacer()
                    Text("As of \(summary.date, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Chart(summary.categories.prefix(5)) { category in
                    BarMark(x: .value("Size", Double(category.bytes)), y: .value("Category", category.kind.rawValue))
                        .foregroundStyle(category.kind.color)
                        .accessibilityLabel(Text(category.kind.title))
                        .accessibilityValue(category.bytes.formattedBytes)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { value in
                        if let raw = value.as(String.self), let kind = StorageCategoryKind(rawValue: raw) {
                            AxisValueLabel { Text(kind.title).font(.caption) }
                        }
                    }
                }
                .frame(height: 110)
            }
        } else {
            Text("No scan of the startup disk yet. Categories appear after the first one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func openMain() {
        NSApp.activate()
        openWindow(id: StofiApp.mainWindowID)
    }
}
