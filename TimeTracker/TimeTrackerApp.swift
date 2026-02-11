import SwiftUI
internal import Combine

@main
struct TimeTrackerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView(state: state)
        } label: {
            MenuBarLabelView(state: state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            Text("TimeTracker")
                .padding()
        }
    }
}
