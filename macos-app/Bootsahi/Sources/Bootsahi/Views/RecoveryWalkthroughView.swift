import SwiftUI

/// DESIGN.md calls this out as "the one step no software can do... invest
/// UX effort there; it's where every first-time Asahi user gets lost."
/// This skeleton has the structure (illustrated steps + a QR code) but not
/// the actual illustrations or a real QR generator — both are D4 work that
/// needs real content/design, not something to fabricate here.
struct RecoveryWalkthroughView: View {
    @EnvironmentObject var flow: InstallFlowViewModel

    private let steps = [
        "Wait 25 seconds for the system to fully shut down.",
        "Press and hold the power button to power on the system.",
        "Release once you see \u{201C}Loading startup options\u{2026}\u{201D} or a spinner.",
        "Wait for the volume list to appear, then choose the new install.",
        "Follow the on-screen installer prompts.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One more step").font(.largeTitle).bold()
            Text("Your Mac needs to shut down and boot into recoveryOS to finish the install.")
                .foregroundStyle(.secondary)

            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top) {
                    Text("\(i + 1).").bold()
                    Text(step)
                }
            }

            // TODO: real QR code generation (CoreImage CIFilter.qrCodeGenerator
            // pointed at a docs URL) so the user can keep reading instructions
            // on their phone while the Mac reboots — not implemented here.
            Text("[QR code placeholder — phone-scannable continuation link]")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .border(.secondary)

            Button("I understand, shut down now") {
                flow.confirmRecoveryOSComplete()
            }
        }
        .padding(40)
    }
}
