import SwiftUI

struct OptionsView: View {
    @EnvironmentObject var flow: InstallFlowViewModel
    @State private var wantsEncryption = false
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

            Section("Disk encryption") {
                Toggle("Encrypt with LUKS", isOn: $wantsEncryption)
                if wantsEncryption {
                    Text("You'll set the disk passphrase on this Mac's first "
                         + "start-up in Linux. It is never saved to disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                if wantsEncryption {
                    flow.config.encryption = .init(type: "luks-passphrase")
                } else {
                    flow.config.encryption = .init(type: "none")
                }
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
