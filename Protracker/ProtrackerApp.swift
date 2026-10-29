import SwiftUI
import AppKit

@main
struct ProtrackerApp: App {
    @NSApplicationDelegateAdaptor(TrackerAppDelegate.self) private var delegate
    @StateObject private var store = TrackerStore.shared
    var body: some Scene {
        WindowGroup {
            ContentView(store:store).frame(idealWidth:1220,idealHeight:870)
        }
        .commands {
            CommandGroup(replacing:.newItem) {
                Button("Neues Modul",action:store.newModule).keyboardShortcut("n")
                Button("Öffnen …",action:store.open).keyboardShortcut("o")
                Button("Demo laden",action:store.loadDemo)
            }
            CommandGroup(replacing:.saveItem) {
                Button("Sichern",action:{ store.save() }).keyboardShortcut("s")
                Button("Sichern unter …",action:{ store.save(as:true) }).keyboardShortcut("s",modifiers:[.command,.shift])
                Button("WAV exportieren …",action:store.exportWAV).keyboardShortcut("e",modifiers:[.command,.shift]).disabled(store.exporting)
            }
            CommandGroup(replacing:.undoRedo) {
                Button("Widerrufen",action:{ store.undoManager.undo() }).keyboardShortcut("z").disabled(!store.undoManager.canUndo)
                Button("Wiederholen",action:{ store.undoManager.redo() }).keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!store.undoManager.canRedo)
            }
            CommandMenu("Tracker") {
                Button(store.playing ? "Stop" : "Song abspielen",action:store.togglePlay).keyboardShortcut(.space,modifiers:[])
                Button("Pattern abspielen",action:{ store.play(pattern:true) }).keyboardShortcut(.return,modifiers:[.command])
                Button("Ab Cursor abspielen",action:{ store.play(fromCursor:true) })
                Button("Edit umschalten",action:{ store.editMode.toggle() })
                Divider()
                Button("Pattern kopieren",action:store.copyPattern).keyboardShortcut("c",modifiers:[.command,.shift])
                Button("Pattern einsetzen",action:store.pastePattern).keyboardShortcut("v",modifiers:[.command,.shift])
                Button("Pattern duplizieren",action:store.duplicatePattern)
                Button("Pattern löschen",action:store.clearPattern)
                Divider()
                Button("Spur +1 Halbton",action:{ store.transpose(1) })
                Button("Spur −1 Halbton",action:{ store.transpose(-1) })
                Divider()
                Button("Sample importieren …",action:store.importSample).keyboardShortcut("i")
                Button("Sample als WAV …",action:store.exportSample)
                Button("Sample normalisieren",action:store.normalizeSample)
                Button("Sample umkehren",action:store.reverseSample)
                Divider()
                Toggle("CIA-Timing",isOn:Binding(get:{ store.module.ciaTiming },set:{ v in store.change("Timing") { $0.ciaTiming = v } }))
            }
            CommandGroup(replacing:.help) { Button("Protracker-Hilfe",action:{ store.showsHelp = true }).keyboardShortcut("?") }
        }
    }
}

@MainActor
final class TrackerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TrackerStore.shared.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { TrackerStore.shared.stop() }
}
