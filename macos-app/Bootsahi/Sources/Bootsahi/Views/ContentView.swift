import SwiftUI

struct ContentView: View {
    @EnvironmentObject var flow: InstallFlowViewModel

    var body: some View {
        Group {
            switch flow.step {
            case .welcome:
                WelcomeView()
            case .catalog:
                CatalogView()
            case .options:
                OptionsView()
            case .diskSlider, .installing:
                InstallProgressView()
            case .recoveryWalkthrough:
                RecoveryWalkthroughView()
            case .done:
                TerminalView(
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    title: "Installation complete",
                    message: "Follow the on-screen instructions to bless the new "
                           + "install, then restart.")
            case .failed(let reason):
                TerminalView(
                    symbol: "xmark.circle.fill",
                    tint: .red,
                    title: "Installation failed",
                    message: reason)
            }
        }
        // A crossfade rather than a hard cut. macOS assistants transition; a
        // full-window instant swap reads as a page load, which is a large part
        // of why this app felt like a website in a window.
        .animation(.easeInOut(duration: 0.18), value: flow.step)
        .onAppear { flow.startE2EDriveIfEnabled() }
    }
}

/// Shared end-of-flow screen for both success and failure.
///
/// They were previously two ad-hoc VStacks with different spacing, and the
/// failure one showed a bare `Text(reason)` the user could not select.
private struct TerminalView: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(title)
                .font(.title.weight(.semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Always selectable, including on success: the failure reason is
                // the one thing a user gets asked for in a bug report, and it is
                // usually a long backend string. Copyable beats retyping it from
                // a screenshot.
                .textSelection(.enabled)
                .frame(maxWidth: 460)
        }
        .padding(Metrics.margin * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
