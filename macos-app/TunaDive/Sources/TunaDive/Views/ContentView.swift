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
                VStack(spacing: 16) {
                    Text("Done").font(.largeTitle)
                    Text("Follow the on-screen instructions to bless the new install, then reboot.")
                }
                .padding()
            case .failed(let reason):
                VStack(spacing: 16) {
                    Text("Installation failed").font(.largeTitle)
                    Text(reason).foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .onAppear { flow.startE2EDriveIfEnabled() }
    }
}
