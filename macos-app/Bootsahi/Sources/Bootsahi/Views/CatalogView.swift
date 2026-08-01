import SwiftUI

struct CatalogView: View {
    @EnvironmentObject var flow: InstallFlowViewModel

    var body: some View {
        WizardPage(
            symbol: "shippingbox",
            title: "Choose what to install",
            subtitle: "Every option is a bootc image. You can rebase to another one "
                    + "later without reinstalling."
        ) {
            Group {
                if let catalog = flow.catalog, !catalog.entries.isEmpty {
                    list(catalog.entries)
                } else {
                    emptyState
                }
            }
        } actions: {
            Button("Continue") { flow.advanceToOptions() }
                .primaryAction()
                .disabled(flow.selectedEntry == nil)
        }
    }

    private func list(_ entries: [CatalogEntry]) -> some View {
        // A selectable List is the macOS idiom here: it brings keyboard
        // navigation, the correct selection highlight in both appearances, and
        // focus-ring behaviour that a stack of custom tappable rows would each
        // have to reimplement, badly.
        List(entries, selection: $flow.selectedEntry) { entry in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cube.transparent")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.variant.capitalized)
                            .font(.headline)
                        Text(entry.desktop)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        StreamBadge(stream: entry.stream)
                    }
                    Text(entry.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The image reference is what actually gets installed, and
                    // it is what a user pastes into a bug report. Worth showing,
                    // in the font that signals "copy this verbatim".
                    Text(entry.imgref)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)
            .tag(entry as CatalogEntry?)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder
    private var emptyState: some View {
        // TODO: catalog.json generation in CI doesn't exist yet (D3 milestone
        // item). Bundling a static placeholder until that job lands.
        let message = "Catalog generation in CI is still to be built, so there is "
                    + "nothing to choose from yet."
        if #available(macOS 14.0, *) {
            ContentUnavailableView {
                Label("No images available", systemImage: "shippingbox")
            } description: {
                Text(message)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text("No images available").font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Release stream, as a quiet capsule rather than parenthesised text.
///
/// It then reads as metadata instead of as part of the name, and colour carries
/// the one thing that matters at a glance: whether this build is meant to be
/// stable.
private struct StreamBadge: View {
    let stream: String

    var body: some View {
        Text(stream)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("\(stream) stream")
    }

    private var tint: Color {
        switch stream.lowercased() {
        case "stable": return .green
        case "testing", "beta": return .orange
        default: return .secondary
        }
    }
}
