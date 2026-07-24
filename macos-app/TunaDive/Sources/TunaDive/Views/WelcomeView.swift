import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var flow: InstallFlowViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text("Tuna Dive").font(.largeTitle).bold()
            Text("Install TunaOS, Dakota, or Bluefin on this Apple Silicon Mac.")
                .foregroundStyle(.secondary)

            // TODO (D4 territory): SoC-generation gate. DESIGN.md's
            // constraints section requires refusing politely, before any
            // work starts, on M3+ Macs (not yet supported by Asahi) — via
            // sysctl hw.model / IORegistry, not left to the backend to
            // discover partway through.

            Button("Get Started") {
                if let url = Bundle.main.url(forResource: "catalog", withExtension: "json") {
                    flow.loadCatalog(from: url)
                }
                flow.advanceToCatalog()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}
