import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var flow: InstallFlowViewModel
    private let hardware = HardwareGate.current()

    private var hardwareUnsupported: Bool {
        if case .unsupported = hardware { return true }
        return false
    }

    /// What the user is agreeing to, said plainly and up front.
    ///
    /// A destructive, hour-long, reboot-into-recovery operation should not open
    /// on a bare "Get Started". macOS setup assistants state the shape of the
    /// job before the first irreversible step, and this one repartitions the
    /// disk the user is currently running from.
    private struct Point: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private let points: [Point] = [
        .init(symbol: "internaldrive",
              title: "Shares this disk",
              detail: "macOS stays installed. You choose how much space to hand over, "
                    + "and you can pick either system at start-up."),
        .init(symbol: "arrow.down.circle",
              title: "Downloads on first start-up",
              detail: "A small bootstrap system is installed now; the desktop you pick "
                    + "is fetched the first time it boots, so keep your Wi-Fi details handy."),
        .init(symbol: "power",
              title: "Finishes in recoveryOS",
              detail: "The last step happens after a shutdown, in Apple's own recovery "
                    + "environment. We'll walk you through it."),
    ]

    var body: some View {
        WizardPage(
            symbol: "sparkles",
            title: "Bootsahi",
            subtitle: "Install TunaOS, Dakota, or Bluefin alongside macOS on this "
                    + "Apple Silicon Mac."
        ) {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                ForEach(points) { point in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: point.symbol)
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.title).font(.headline)
                            Text(point.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                if case .unsupported(let model, let reason) = hardware {
                    Label {
                        Text("Model \(model): \(reason)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        } actions: {
            Button("Continue") {
                if let url = Bundle.main.url(forResource: "catalog", withExtension: "json") {
                    flow.loadCatalog(from: url)
                }
                flow.advanceToCatalog()
            }
            .primaryAction()
            .disabled(hardwareUnsupported)
        }
    }
}
