import SwiftUI

@main
struct BootsahiApp: App {
    @StateObject private var flow = InstallFlowViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(flow)
                .frame(minWidth: 640, minHeight: 480)
        }
    }
}
