import SwiftUI

@main
struct BootsahiApp: App {
    @StateObject private var flow = InstallFlowViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(flow)
                .frame(minWidth: 720, minHeight: 560)
        }
        // A single-window assistant, so: one window, no tabs, no "New Window".
        // Leaving the defaults in place gave this app a File > New Window that
        // opened a second, independent installer — a genuinely dangerous
        // affordance for something that repartitions a disk, and the kind of
        // detail that makes an app feel un-Mac precisely because the menus are
        // wrong rather than the pixels.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
