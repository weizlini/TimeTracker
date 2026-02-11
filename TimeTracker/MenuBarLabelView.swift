import SwiftUI
internal import Combine

struct MenuBarLabelView: View {
    @ObservedObject var state: AppState

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")

            // Reserve fixed slot width and show the timer left-aligned.
            Text(title(now: now))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .frame(width: 72, alignment: .leading)
        }
        .frame(width: 100, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .onReceive(ticker) { d in now = d }
    }

    private func title(now: Date) -> String {
        if let running = state.runningEntry {
            let secs = max(0, Int(now.timeIntervalSince(running.startAt)))
            return formatHMS(secs)
        }

        if let pid = state.selectedProjectId {
            let secs = state.totalSecondsTodayLive(for: pid, at: now)
            return formatHMS(secs)
        }

        return "--:--:--"
    }

    private func formatHMS(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
