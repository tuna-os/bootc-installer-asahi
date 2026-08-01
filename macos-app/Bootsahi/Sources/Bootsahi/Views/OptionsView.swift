import SwiftUI

struct OptionsView: View {
    @EnvironmentObject var flow: InstallFlowViewModel
    @State private var wifiSSID = ""

    var body: some View {
        Form {
            Section("System") {
                TextField("Hostname", text: $flow.config.hostname)
            }

            Section("User account") {
                TextField("Username", text: usernameBinding)
                SecureField("Password", text: passwordBinding)
            }

            // Offering this control while the agent refuses encryption is
            // worse than not offering it. fisherman's customMounts path — the
            // only path this installer uses — never runs luksFormat/luksOpen
            // (issue #20), so the agent fails closed on any
            // encryption.type != "none". That refusal happens at FIRST BOOT,
            // which is after the Mac's disk has been repartitioned and the
            // payload written. A toggle here would therefore turn a choice
            // the user makes in five seconds into a failed install they
            // discover an hour later, on the far side of the destructive step.
            //
            // So the control is disabled rather than removed: the user learns
            // encryption is unavailable BEFORE partitioning, and re-enabling
            // it once the manual path implements LUKS is a local change here
            // plus lifting the agent's refusal.
            Section("Disk encryption") {
                Toggle("Encrypt with LUKS", isOn: .constant(false))
                    .disabled(true)
                Text("Not available yet. The installer would have to leave the "
                     + "disk unencrypted after telling you it was encrypted, "
                     + "so it refuses instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Wi-Fi") {
                // DESIGN.md D4: read the current SSID from macOS
                // (SystemConfiguration) and prefill this — never the
                // password, the user always re-enters it. Not implemented
                // in this skeleton; wifiSSID is a plain manual field.
                TextField("Network name (SSID)", text: $wifiSSID)
                Text("You'll be asked for the Wi-Fi password on this Mac's first "
                     + "start-up in Linux. It is never saved to disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Continue") {
                // Emitted explicitly rather than left nil: the agent defaults a
                // missing encryption block to "none" anyway, but writing it
                // makes the config state what was decided instead of relying
                // on both sides agreeing about absence.
                flow.config.encryption = .init(type: "none")
                if !wifiSSID.isEmpty {
                    flow.config.wifi = .init(ssid: wifiSSID)
                }
                flow.advanceToDiskSlider()
            }
            .disabled(flow.config.hostname.isEmpty)
        }
        .padding()
    }

    private var usernameBinding: Binding<String> {
        Binding(
            get: { flow.config.user?.username ?? "" },
            set: { flow.config.user = .init(username: $0, fullname: nil, password: flow.config.user?.password ?? "", groups: ["wheel"]) }
        )
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { flow.config.user?.password ?? "" },
            set: { flow.config.user = .init(username: flow.config.user?.username ?? "", fullname: nil, password: $0, groups: ["wheel"]) }
        )
    }
}
