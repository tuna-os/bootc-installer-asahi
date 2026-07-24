import SwiftUI

struct CatalogView: View {
    @EnvironmentObject var flow: InstallFlowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose what to install").font(.title2).bold()

            if let catalog = flow.catalog, !catalog.entries.isEmpty {
                List(catalog.entries, selection: $flow.selectedEntry) { entry in
                    VStack(alignment: .leading) {
                        Text("\(entry.variant) — \(entry.desktop) (\(entry.stream))").bold()
                        Text(entry.description).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(entry as CatalogEntry?)
                }
            } else {
                // TODO: catalog.json generation in CI doesn't exist yet
                // (D3 milestone item). Bundling a static placeholder here
                // until that job lands.
                Text("No catalog loaded — catalog.json generation in CI is still TODO.")
                    .foregroundStyle(.secondary)
            }

            Button("Continue") { flow.advanceToOptions() }
                .disabled(flow.selectedEntry == nil)
        }
        .padding()
    }
}
