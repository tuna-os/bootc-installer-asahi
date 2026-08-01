import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// DESIGN.md calls this out as "the one step no software can do... invest UX
/// effort there; it's where every first-time Asahi user gets lost."
///
/// The design constraint that shapes this whole screen: the user has to read
/// these instructions *while the Mac is off*. So the steps are sized to be read
/// across a desk, the destructive/irreversible bit is called out before the
/// button rather than after it, and the QR code is real — it is the only way
/// the instructions survive the shutdown.
struct RecoveryWalkthroughView: View {
    @EnvironmentObject var flow: InstallFlowViewModel

    /// TODO (D4): point this at the published walkthrough once docs land. The
    /// QR generator below is real; only the destination is provisional.
    private let continuationURL = "https://github.com/tuna-os/bootc-installer-asahi"

    private let steps = [
        "Wait 25 seconds for the system to fully shut down.",
        "Press and hold the power button to power on the system.",
        "Release once you see \u{201C}Loading startup options\u{2026}\u{201D} or a spinner.",
        "Wait for the volume list to appear, then choose the new install.",
        "Follow the on-screen installer prompts.",
    ]

    var body: some View {
        WizardPage(
            symbol: "power",
            title: "One more step",
            subtitle: "Your Mac needs to shut down and start up in recoveryOS to "
                    + "finish the install."
        ) {
            HStack(alignment: .top, spacing: Metrics.margin) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            // A numbered token rather than "1." in body text:
                            // it survives being read at arm's length, which is
                            // the actual reading condition here.
                            Text("\(i + 1)")
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.accentColor))
                                .accessibilityHidden(true)
                            Text(step)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(i + 1). \(step)")
                    }

                    Label {
                        Text("Hold the power button down. A normal press just starts "
                             + "macOS again.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                continuationCard
            }
        } actions: {
            Button("Shut Down") { flow.confirmRecoveryOSComplete() }
                .primaryAction()
        }
    }

    private var continuationCard: some View {
        VStack(spacing: 8) {
            if let image = qrImage(for: continuationURL) {
                Image(nsImage: image)
                    .interpolation(.none) // keep the modules crisp
                    .resizable()
                    .frame(width: 132, height: 132)
                    .accessibilityLabel("QR code linking to the recovery walkthrough")
            } else {
                // Never a broken-image box: if generation fails the user still
                // needs the destination, so fall back to the text of it.
                Text(continuationURL)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(width: 132)
            }
            Text("Keep reading on your phone")
                .font(.callout.weight(.medium))
            Text("The Mac is about to shut down.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Metrics.margin)
        .wizardSurface()
    }

    /// Real QR generation via CoreImage — this replaced a
    /// "[QR code placeholder]" string. The placeholder was the single worst
    /// thing on this screen: it occupied the spot where the user's only
    /// post-shutdown lifeline belongs, so the screen looked finished while
    /// offering nothing at the moment the Mac goes dark.
    private func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // "M" — ~15% recoverable. Enough to survive a phone camera at an angle
        // without inflating the module count past what 132pt can resolve.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // Scale in CoreImage rather than letting the view stretch an 25pt
        // bitmap: upscaling a QR in the view produces the soft edges that make
        // phone cameras hunt for focus.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width,
                                                      height: scaled.extent.height))
    }
}
