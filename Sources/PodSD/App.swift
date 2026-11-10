import SwiftUI

@main
struct PodSDApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("PodSD") {
            ContentView().environmentObject(store)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Download Folder") { reveal(Paths.downloadsRoot) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
