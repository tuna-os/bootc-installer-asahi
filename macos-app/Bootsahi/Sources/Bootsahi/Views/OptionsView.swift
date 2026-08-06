import SwiftUI

struct OptionsView: View {
    @EnvironmentObject var flow: InstallFlowViewModel
    @State private var wifiSSID = ""
    // Plaintext lives HERE, in the view, and never in the view model.
    // InstallFlowViewModel outlives this screen and is what gets serialised
    // into the E2E state report; a password parked on it is a password with
    // more ways out of the process than it needs. The model only ever receives
    // the $6$ hash, on Continue.
    @State private var password = ""

    /// Screenshot/preview seam. The password is view-local `@State` now, so a
    /// fixture view model cannot reach it — and a documentation screenshot of
    /// this screen with an empty password field and a disabled Continue button
    /// would misrepresent the step it is supposed to explain.
    init(previewPassword: String = "") {
        _password = State(initialValue: previewPassword)
    }

    var body: some View {
        WizardPage(
            symbol: "gearshape",
            title: "Set up your system",
            subtitle: "These settings are applied the first time the new system starts."
        ) {
            // `.formStyle(.grouped)` is the whole reason this screen now reads
            // as a Mac app: it produces System Settings' inset grouped cards,
            // with labels in the leading column, correct row heights and
            // section footers. The previous plain Form fell back to a bare
            // stack of controls, which is the SwiftUI-on-iOS look transplanted
            // into a window.
            Form {
                Section {
                    LabeledContent("Computer name") {
                        TextField("Computer name", text: $flow.config.hostname, prompt: Text("bootsahi"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                } header: {
                    Text("System")
                } footer: {
                    Text("Used as the hostname on your network.")
                }

                Section {
                    LabeledContent("Full name") {
                        TextField("Full name", text: fullnameBinding, prompt: Text("Optional"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                    LabeledContent("Account name") {
                        TextField("Account name", text: usernameBinding)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                    LabeledContent("Password") {
                        SecureField("Password", text: $password)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                } header: {
                    Text("Administrator account")
                } footer: {
                    Text("This account can use `sudo`. The password is hashed on this "
                         + "Mac before anything is written to disk \u{2014} the file it "
                         + "goes into is readable by anyone who has the machine.")
                }

                // Offering this control while the agent refuses encryption is
                // worse than not offering it. fisherman's customMounts path —
                // the only path this installer uses — never runs
                // luksFormat/luksOpen (issue #20), so the agent fails closed on
                // any encryption.type != "none". That refusal happens at FIRST
                // BOOT, which is after the Mac's disk has been repartitioned and
                // the payload written. A live toggle here would therefore turn a
                // choice the user makes in five seconds into a failed install
                // they discover an hour later, past the destructive step.
                //
                // So the control is disabled rather than removed: the user learns
                // encryption is unavailable BEFORE partitioning, and re-enabling
                // it once the manual path implements LUKS is a local change here
                // plus lifting the agent's refusal.
                Section {
                    Toggle("Encrypt the Linux volume", isOn: .constant(false))
                        .disabled(true)
                    // An inline notice rather than grey caption text: a disabled
                    // control with no stated reason reads as a bug, and users
                    // retry it. Saying why, next to it, is the difference
                    // between "broken" and "deliberate".
                    Label {
                        Text("Not available yet. The installer would have to leave the "
                             + "volume unencrypted after telling you it was encrypted, "
                             + "so it declines instead.")
                    } icon: {
                        // Deliberately a symbol that has shipped since SF
                        // Symbols 1 — the deployment target is macOS 13, and a
                        // symbol added later renders as an empty box there
                        // rather than failing to build.
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Disk encryption")
                }

                Section {
                    // DESIGN.md D4: read the current SSID from macOS
                    // (SystemConfiguration) and prefill this — never the
                    // password, the user always re-enters it. Not implemented
                    // in this skeleton; wifiSSID is a plain manual field.
                    LabeledContent("Network name") {
                        TextField("Network name", text: $wifiSSID, prompt: Text("Optional"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                    Label {
                        Text("You'll be asked for the Wi-Fi password on this Mac's first "
                             + "start-up in Linux. It is never written to disk here.")
                    } icon: {
                        Image(systemName: "hand.raised")
                            .foregroundStyle(.tint)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Wi-Fi")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } actions: {
            Button("Continue") {
                // Emitted explicitly rather than left nil: the agent defaults a
                // missing encryption block to "none" anyway, but writing it
                // makes the config state what was decided instead of relying on
                // both sides agreeing about the meaning of absence.
                flow.config.encryption = .init(type: "none")
                // Hash HERE rather than at write time. writeInstallConfig() is
                // still unimplemented, and whoever implements it should find a
                // config that already carries a $6$ hash rather than a plaintext
                // password plus a comment asking them to remember. The agent
                // refuses plaintext (#21), so forgetting would not be a silent
                // weakness — it would be an install that fails at first boot,
                // after the disk is already repartitioned.
                updateUser(password: PasswordHash.hash(password))
                if !wifiSSID.isEmpty {
                    flow.config.wifi = .init(ssid: wifiSSID)
                }
                flow.advanceToDiskSlider()
            }
            .primaryAction()
            .disabled(!isComplete)
        }
    }

    /// Every field the first-boot agent needs. An account with no password
    /// would be a passwordless sudoer on a machine exposed to the network, so
    /// it is a precondition rather than a warning.
    private var isComplete: Bool {
        !flow.config.hostname.isEmpty
            && !(flow.config.user?.username ?? "").isEmpty
            && !password.isEmpty
    }

    // Each field writes back through the whole UserSpec because InstallConfig's
    // `user` is a single optional value, not independently observable fields.
    private var usernameBinding: Binding<String> {
        Binding(
            get: { flow.config.user?.username ?? "" },
            set: { updateUser(username: $0) }
        )
    }

    private var fullnameBinding: Binding<String> {
        Binding(
            get: { flow.config.user?.fullname ?? "" },
            set: { updateUser(fullname: $0.isEmpty ? nil : $0) }
        )
    }


    private func updateUser(
        username: String? = nil,
        fullname: String?? = nil,
        password: String? = nil
    ) {
        let current = flow.config.user
        // Spelled out into typed locals rather than one `.init(...)` of `??`
        // chains. SwiftUI's type checker has to solve a view body's expressions
        // together, and a four-argument initialiser whose arguments each hang
        // off an optional chain — one of them a `String??` being flattened —
        // was enough to push this past the solver's budget and fail the macOS
        // build with "unable to type-check this expression in reasonable time".
        // Annotating each local gives it the answer instead of asking for it.
        let newUsername: String = username ?? current?.username ?? ""
        let newFullname: String? = fullname ?? current?.fullname
        let newPassword: String = password ?? current?.password ?? ""
        let newGroups: [String] = current?.groups ?? ["wheel"]
        flow.config.user = InstallConfig.UserSpec(
            username: newUsername,
            fullname: newFullname,
            password: newPassword,
            groups: newGroups)
    }
}
