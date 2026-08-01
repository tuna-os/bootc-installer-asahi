import SwiftUI

/// Renders backend progress messages, and whatever ask (if any) is currently
/// outstanding. Covers both the .diskSlider step (the backend's first `size`
/// ask, for the APFS resize) and .installing (everything after) — in practice
/// they're the same screen, since asks of any kind can arrive at any point in
/// the backend's own flow.
struct InstallProgressView: View {
    @EnvironmentObject var flow: InstallFlowViewModel
    @State private var showLog = false

    var body: some View {
        WizardPage(
            symbol: "arrow.down.circle",
            title: flow.pendingAsk == nil ? "Installing" : "One question",
            subtitle: flow.pendingAsk == nil
                ? "Leave this Mac plugged in and awake."
                : nil
        ) {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if let ask = flow.pendingAsk {
                    AskView(ask: ask) { flow.answer($0) }
                        .padding(Metrics.margin)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .wizardSurface()
                } else {
                    activity
                }

                logSection
            }
        } actions: {
            // No primary button here on purpose: the backend drives this step,
            // and any button offering to move on would either lie or abandon a
            // half-written disk. The disclosure control is the only affordance.
            Toggle(isOn: $showLog) {
                Label(showLog ? "Hide details" : "Show details",
                      systemImage: showLog ? "chevron.down" : "chevron.right")
            }
            .toggleStyle(.button)
            .controlSize(.large)
        }
    }

    /// The last thing the backend said, given prominence, with an indeterminate
    /// bar. The backend does not report a completion fraction, so a determinate
    /// bar here would be fiction — and a progress bar that lies is worse than
    /// one that simply spins.
    private var activity: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.log.last?.text ?? "Starting…")
                    .font(.body)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This can take a while.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wizardSurface()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var logSection: some View {
        if showLog {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(flow.log.enumerated()), id: \.offset) { _, msg in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // Level as a symbol as well as a colour: colour
                            // alone fails for the ~8% of men with a colour
                            // vision deficiency, and red-vs-green is exactly
                            // the distinction that matters in an install log.
                            Image(systemName: symbol(for: msg.level))
                                .font(.caption2)
                                .foregroundStyle(style(for: msg.level))
                                .accessibilityHidden(true)
                            Text(msg.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    private func symbol(for level: MessageLevel) -> String {
        switch level {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .progress, .info, .message: return "arrow.right.circle"
        case .question, .prompt, .choice: return "questionmark.circle"
        case .plain: return "circle"
        }
    }

    private func style(for level: MessageLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .progress, .info, .message: return .accentColor
        default: return .secondary
        }
    }
}

// MARK: - Asks

private struct AskView: View {
    let ask: BackendAsk
    let respond: (JSONValue?) -> Void

    @State private var sizeBytes: Double = 0
    @State private var textValue: String = ""
    @State private var choice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ask.prompt)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            switch ask.kind {
            case .choice:
                choicePicker

            case .yesno:
                HStack(spacing: 10) {
                    Button("Continue") { respond(.bool(true)) }.primaryAction()
                    Button("Cancel") { respond(.bool(false)) }
                        .secondaryAction()
                        .keyboardShortcut(.cancelAction)
                }

            case .size:
                sizeSlider

            case .password, .input:
                HStack(spacing: 10) {
                    Group {
                        if ask.kind == .password {
                            SecureField("Password", text: $textValue)
                        } else {
                            TextField("", text: $textValue)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    Button("Continue") { respond(.string(textValue)) }.primaryAction()
                }

            case .continueAck:
                Button("Continue") { respond(.null) }.primaryAction()
            }
        }
        .onAppear(perform: seedDefaults)
    }

    private var choicePicker: some View {
        // Radio buttons rather than a row of push buttons: these are mutually
        // exclusive choices the user reviews before committing, which is
        // exactly what `.radioGroup` means on macOS. A row of buttons instead
        // fires an irreversible action on first click, with no chance to read
        // the other options first.
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $choice) {
                ForEach(sortedOptions, id: \.key) { key, label in
                    Text(label).tag(String?.some(key))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Button("Continue") {
                if let choice { respond(.string(choice)) }
            }
            .primaryAction()
            .disabled(choice == nil)
        }
    }

    /// The size ask carries real byte counts (`min`/`max`/`total`), and the
    /// previous version ignored them: it showed a 0–100 percentage and sent the
    /// literal string "50%". That is not a rendering shortcut, it is a wrong
    /// answer on the wire — this ask is the APFS resize, so the number decides
    /// how much of the user's disk macOS keeps.
    private var sizeSlider: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(format(Int64(sizeBytes)))
                    .font(.title2.weight(.medium).monospacedDigit())
                Text("for Linux")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let total = ask.total {
                    Text("\(format(total - Int64(sizeBytes))) left for macOS")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Slider(
                value: $sizeBytes,
                in: Double(ask.min ?? 0)...Double(max(ask.max ?? 1, (ask.min ?? 0) + 1))
            ) {
                Text("Space for Linux")
            } minimumValueLabel: {
                Text(format(ask.min ?? 0)).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(format(ask.max ?? 0)).font(.caption).foregroundStyle(.secondary)
            }
            .labelsHidden()

            Button("Continue") { respond(.int(Int64(sizeBytes))) }
                .primaryAction()
        }
    }

    private func seedDefaults() {
        switch ask.kind {
        case .size:
            // Prefer the backend's own default; fall back to the low end rather
            // than the midpoint, because the conservative choice is the one that
            // leaves the user's existing macOS install the most room.
            switch ask.defaultValue {
            case .int(let v): sizeBytes = Double(v)
            case .double(let v): sizeBytes = v
            default: sizeBytes = Double(ask.min ?? 0)
            }
        case .choice:
            choice = ask.defaultValue?.stringValue ?? sortedOptions.first?.key
        case .input:
            textValue = ask.defaultValue?.stringValue ?? ""
        default:
            break
        }
    }

    private func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }

    private var sortedOptions: [(key: String, value: String)] {
        (ask.options ?? [:]).sorted { $0.key < $1.key }
    }
}
