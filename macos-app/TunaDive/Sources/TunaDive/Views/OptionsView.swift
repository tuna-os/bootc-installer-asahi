import SwiftUI

struct OptionsView: View {
    @EnvironmentObject var flow: InstallFlowViewModel
    @State private var passphrase = ""
    @State private var wantsEncryption = false
    @State private var wifiSSID = ""
    @State private var wifiPSK = ""

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
                    SecureField("Passphrase", text: $passphrase)
                }
            }

            Section("Wi-Fi") {
                // DESIGN.md D4: read the current SSID from macOS
                // (SystemConfiguration) and prefill this — never the
                // password, the user always re-enters it. Not implemented
                // in this skeleton; wifiSSID is a plain manual field.
                TextField("Network name (SSID)", text: $wifiSSID)
                SecureField("Wi-Fi password", text: $wifiPSK)
            }

            Button("Continue") {
                if wantsEncryption {
                    flow.config.encryption = .init(type: "luks-passphrase", passphrase: passphrase)
                } else {
                    flow.config.encryption = .init(type: "none", passphrase: nil)
                }
                if !wifiSSID.isEmpty {
                    flow.config.wifi = .init(ssid: wifiSSID, psk: wifiPSK.isEmpty ? nil : wifiPSK)
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
