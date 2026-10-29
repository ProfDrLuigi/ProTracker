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
                Button(L("Neues Modul"),action:store.newModule).keyboardShortcut("n")
                Button(L("Öffnen …"),action:store.open).keyboardShortcut("o")
                Button(L("Demo laden"),action:store.loadDemo)
            }
            CommandGroup(replacing:.saveItem) {
                Button(L("Sichern"),action:{ store.save() }).keyboardShortcut("s")
                Button(L("Sichern unter …"),action:{ store.save(as:true) }).keyboardShortcut("s",modifiers:[.command,.shift])
                Button(L("WAV exportieren …"),action:store.exportWAV).keyboardShortcut("e",modifiers:[.command,.shift]).disabled(store.exporting)
            }
            CommandGroup(replacing:.printItem) { Button(L("Song drucken …"),action:store.printSong).keyboardShortcut("p") }
            CommandGroup(replacing:.undoRedo) {
                Button(L("Widerrufen"),action:{ store.undoManager.undo() }).keyboardShortcut("z").disabled(!store.undoManager.canUndo)
                Button(L("Wiederholen"),action:{ store.undoManager.redo() }).keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!store.undoManager.canRedo)
            }
            CommandGroup(after:.appSettings) {
                Button(L("Setup …"),action:{ store.openWorkbench(.settings) }).keyboardShortcut(",")
            }
            CommandMenu("Sampler") {
                Button(L("Sampler öffnen …"),action:{ store.openWorkbench(.sample) }).keyboardShortcut("i",modifiers:[.command,.shift])
                Button(L("Preset-Liste …"),action:{ store.openWorkbench(.presets) }).keyboardShortcut("l")
                Button(L("Audio aufnehmen …"),action:{ store.openWorkbench(.recording) }).keyboardShortcut("r")
                Divider()
                Button(L("Bereich ausschneiden"),action:{ store.copySample(cut:true) })
                Button(L("Bereich kopieren"),action:{ store.copySample() })
                Button(L("Bereich einsetzen"),action:store.pasteSample)
                Button(L("Auf Bereich zuschneiden"),action:store.cropSample)
                Button(L("Loop aus Bereich"),action:store.setLoopFromSelection)
                Divider()
                Button(L("Alle Samples exportieren …"),action:store.exportAllSamples)
                Button(L("Aktuelles Sample als Preset"),action:store.addPreset)
            }
            CommandMenu(L("Blocks")) {
                Button(L("Edit operations …"),action:{ store.openWorkbench(.pattern) })
                Button(L("Block markieren"),action:store.markBlock)
                Button(L("Block kopieren"),action:{ store.copyBlock() })
                Button(L("Block ausschneiden"),action:{ store.copyBlock(cut:true) })
                Button(L("Block einsetzen"),action:{ store.pasteBlock() })
                Button(L("Block dazwischen einsetzen"),action:{ store.pasteBlock(insert:true) })
                Button(L("Block mischen"),action:{ store.pasteBlock(mix:true) })
                Button(L("Block umkehren"),action:store.reverseBlock)
                Divider()
                Button(L("Zeile einfügen"),action:{ store.shiftRows(insert:true) })
                Button(L("Zeile entfernen"),action:{ store.shiftRows(insert:false) })
                Button(L("Spur expandieren"),action:{ store.stretchTrack(expand:true) })
                Button(L("Spur komprimieren"),action:{ store.stretchTrack(expand:false) })
                Divider()
                Button(L("Pattern / Spur laden …"),action:store.loadPatternFile)
                Button(L("Pattern speichern …"),action:{ store.savePatternFile() })
                Button(L("Spur speichern …"),action:{ store.savePatternFile(track:true) })
            }
            CommandMenu("Tracker") {
                Button(store.playing ? L("Stop") : L("Song abspielen"),action:store.togglePlay)
                Button(L("Pattern abspielen"),action:{ store.play(pattern:true) }).keyboardShortcut(.return,modifiers:[.command])
                Button(L("Ab Cursor abspielen"),action:{ store.play(fromCursor:true) })
                Button(L("Edit umschalten"),action:{ store.editMode.toggle() })
                Divider()
                Button(L("Pattern kopieren"),action:store.copyPattern).keyboardShortcut("c",modifiers:[.command,.shift])
                Button(L("Pattern einsetzen"),action:store.pastePattern).keyboardShortcut("v",modifiers:[.command,.shift])
                Button(L("Pattern duplizieren"),action:store.duplicatePattern)
                Button(L("Pattern löschen"),action:store.clearPattern)
                Divider()
                Button(L("Spur +1 Halbton"),action:{ store.transpose(1) })
                Button(L("Spur −1 Halbton"),action:{ store.transpose(-1) })
                Divider()
                Button(L("Sample importieren …"),action:store.importSample).keyboardShortcut("i")
                Button(L("Sample als WAV …"),action:store.exportSample)
                Button(L("Sample normalisieren"),action:store.normalizeSample)
                Button(L("Sample umkehren"),action:store.reverseSample)
                Divider()
                Toggle(L("CIA-Timing"),isOn:Binding(get:{ store.module.ciaTiming },set:{ v in store.change("Timing") { $0.ciaTiming = v } }))
            }
            CommandGroup(replacing:.help) { Button(L("Protracker-Hilfe"),action:{ store.showsHelp = true }).keyboardShortcut("?") }
        }
    }
}

@MainActor
final class TrackerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TrackerStore.shared.confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { TrackerStore.shared.stop(); TrackerStore.shared.recorder.stop(); TrackerStore.shared.midi.close(); TrackerStore.shared.flushLibrary() }
}
