# TimeTrackerKit (macOS SwiftUI Menu Bar Time Tracker)

This zip contains the full set of Swift source files for the TimeTracker app we designed:
- Menu bar app (SwiftUI `MenuBarExtra`)
- Project dropdown + add project
- Start/Stop creates time entries (append-only)
- Auto-stops on screensaver / sleep / lock / app deactivation (best-effort)
- Stores JSON on your Desktop: `~/Desktop/TimeTracker/`
- Exports a simplified CSV for Google Sheets

## Create a fresh Xcode project and add these files

1) Xcode → File → New → Project… → macOS → **App**
- Interface: SwiftUI
- Language: Swift

2) Drag all `.swift` files from this folder into your Xcode project (Project Navigator).
- In the “Add files” dialog, **check your target** under “Add to targets”.

3) Replace the template `ContentView.swift` and `YourAppNameApp.swift` with the ones in this zip (or delete template files after adding ours).

4) Turn OFF sandbox (needed to write to Desktop):
- Target → Signing & Capabilities → **App Sandbox** → remove (trash icon)

5) Run (⌘R). The app appears in the menu bar.
- Add a project (+)
- Start/Stop
- Export CSV

## Data locations
- JSON: `~/Desktop/TimeTracker/projects.json`, `~/Desktop/TimeTracker/time_entries.json`
- CSV exports: `~/Desktop/TimeTracker/time_entries-YYYYMMDD-HHMMSS.csv`
