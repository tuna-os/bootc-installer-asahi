import SwiftUI

/// Renders backend progress messages, and whatever ask (if any) is
/// currently outstanding. Covers both the .diskSlider step (the backend's
/// first `size` ask, for the APFS resize) and .installing (everything
/// after) — in practice they're the same screen, since asks of any kind can
/// arrive at any point in the backend's own flow.
struct InstallProgressView: View {
    @EnvironmentObject var flow: InstallFlowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let ask = flow.pendingAsk {
                AskView(ask: ask) { flow.answer($0) }
            } else {
                ProgressView("Working…")
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(flow.log.enumerated()), id: \.offset) { _, msg in
                        Text(msg.text)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(color(for: msg.level))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private func color(for level: MessageLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .yellow
        case .success: return .green
        case .progress, .info: return .blue
        default: return .primary
        }
    }
}

private struct AskView: View {
    let ask: BackendAsk
    let respond: (JSONValue?) -> Void

    @State private var sliderValue: Double = 50
    @State private var textValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ask.prompt).font(.headline)

            switch ask.kind {
            case .choice:
                ForEach(sortedOptions, id: \.key) { key, label in
                    Button(label) { respond(.string(key)) }
                }

            case .yesno:
                HStack {
                    Button("Yes") { respond(.bool(true)) }
                    Button("No") { respond(.bool(false)) }
                }

            case .size:
                // TODO: this should be a real slider bound to ask.min/max/
                // total (bytes), matching DESIGN.md's "disk-space slider".
                // Wired to a percentage placeholder until this can be
                // tried against a real backend session.
                Slider(value: $sliderValue, in: 0...100)
                Text("\(Int(sliderValue))%")
                Button("Confirm") { respond(.string("\(Int(sliderValue))%")) }

            case .password, .input:
                SecureField(ask.kind == .password ? "Password" : "", text: $textValue)
                Button("Submit") { respond(.string(textValue)) }

            case .continueAck:
                Button("Continue") { respond(.null) }
            }
        }
    }

    private var sortedOptions: [(key: String, value: String)] {
        (ask.options ?? [:]).sorted { $0.key < $1.key }
    }
}
