import AppKit

@MainActor
extension TrackerStore {
    private var libraryURL: URL {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Protracker",isDirectory:true)
        return root.appendingPathComponent("Library.ptpresets")
    }
    func loadLibrary() {
        guard FileManager.default.fileExists(atPath:libraryURL.path) else { return }
        do { presets = try PresetDocument.decode(Data(contentsOf:libraryURL)).entries }
        catch { status = "Preset-Liste konnte nicht geladen werden: \(error.localizedDescription)" }
    }
    func persistLibrary() {
        librarySaveTask?.cancel()
        let entries = presets, url = libraryURL
        let item = DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONEncoder().encode(PresetDocument(entries:entries)).write(to:url,options:.atomic)
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.status = "Preset-Liste konnte nicht gespeichert werden: \(message)" }
            }
        }
        librarySaveTask = item; librarySaveQueue.asyncAfter(deadline:.now()+0.4,execute:item)
    }
    func flushLibrary() {
        librarySaveTask?.cancel()
        let entries = presets,url = libraryURL
        librarySaveQueue.sync {
            do { try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try JSONEncoder().encode(PresetDocument(entries:entries)).write(to:url,options:.atomic) }
            catch { status = .verbatim(error.localizedDescription) }
        }
    }
    private func applyLibrary(_ entries: [PresetEntry], name: String) {
        let old = presets
        undoManager.registerUndo(withTarget:self) { $0.applyLibrary(old,name:name) }
        undoManager.setActionName(LK(name)); presets = entries
    }
    func togglePresetFavorite(_ id: UUID) {
        guard let i = presets.firstIndex(where:{ $0.id == id }) else { return }
        var next = presets; next[i].favorite.toggle(); applyLibrary(next,name:"Preset-Favorit")
    }
    func addPreset() {
        guard !sample.pcm.isEmpty else { return }
        appendPresets([PresetEntry(name:sample.name.isEmpty ? "Untitled sample" : sample.name,bank:"My presets",sample:sample)])
    }
    func appendPresets(_ values: [PresetEntry]) {
        var result = presets, bytes = presets.reduce(0) { $0+$1.sample.pcm.count }
        for entry in values {
            if result.count >= 2500 || bytes+entry.sample.pcm.count > 64_000_000 { status = "Bibliotheksgrenze erreicht: 2500 Presets / 64 MB"; break }
            result.append(entry); bytes += entry.sample.pcm.count
        }
        applyLibrary(result,name:"Presets hinzufügen")
    }
    func loadPreset(_ id: UUID, preview: Bool = false) {
        guard let entry = presets.first(where:{ $0.id == id }) else { return }
        if preview {
            // Preview uses a temporary module; it never replaces the user's sample.
            var temporary = module; temporary.samples[selectedSample] = entry.sample
            previewModule(temporary,sample:selectedSample,period:Notes.period((octave-1)*12),channel:selectedChannel)
        } else { sampleChange("Preset laden") { $0 = entry.sample }; selectAllSamples(); status = "Preset geladen: \(entry.name)" }
    }
    func renamePreset(_ id: UUID, name: String? = nil, bank: String? = nil) {
        guard let index = presets.firstIndex(where:{ $0.id == id }) else { return }
        var next = presets
        if let name { next[index].name = String(name.prefix(80)); next[index].sample.name = String(name.prefix(22)) }
        if let bank { next[index].bank = String(bank.prefix(80)) }
        applyLibrary(next,name:"Preset bearbeiten")
    }
    func removePreset(_ id: UUID) { applyLibrary(presets.filter { $0.id != id },name:"Preset entfernen") }
    func removePresetBank(_ bank: String) { applyLibrary(presets.filter { $0.bank != bank },name:"Preset-Bank entfernen") }
    func savePresetList() {
        let panel = NSSavePanel(); panel.prompt = L("Sichern"); panel.allowedFileTypes = ["ptpresets"]; panel.nameFieldStringValue = "Library.ptpresets"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONEncoder().encode(PresetDocument(entries:presets)).write(to:url,options:.atomic) } catch { report(error) }
    }
    func openPresetList() {
        let panel = NSOpenPanel(); panel.prompt = L("Öffnen"); panel.allowedFileTypes = ["ptpresets"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 100_000_000 else { throw ModuleError.invalid("Preset-Datei ist zu groß.") }
            var entries = try PresetDocument.decode(Data(contentsOf:url)).entries
            // Import merges without colliding with IDs already in this library.
            for i in entries.indices where presets.contains(where:{ $0.id == entries[i].id }) { entries[i].id = UUID() }
            appendPresets(entries)
        } catch { report(error) }
    }
    func importPresets(folder: Bool = false) {
        let panel = NSOpenPanel(); panel.prompt = L("Öffnen"); panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = !folder; panel.title = folder ? L("Sample-Ordner zur Preset-Liste hinzufügen") : L("Samples oder Modul zur Preset-Liste hinzufügen")
        guard !libraryImporting, panel.runModal() == .OK else { return }
        let urls = panel.urls; libraryImporting = true
        let scopes = urls.map { $0.startAccessingSecurityScopedResource() }
        DispatchQueue.global(qos:.userInitiated).async {
            var entries: [PresetEntry] = [], failures = 0, bytes = 0
            let extensions = ["wav","aif","aiff","iff","8svx","caf","raw","smp","mod","modl","pp","xpk","pack"]
            var files = urls
            if folder {
                files = urls.flatMap { root -> [URL] in
                    guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else { return [] }
                    return iterator.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension.lowercased()) }.prefix(2500).map { $0 }
                }
            }
            for url in files.prefix(2500) {
                do {
                    let bank = url.deletingLastPathComponent().lastPathComponent
                    if ["mod","modl","pp","xpk","pack"].contains(url.pathExtension.lowercased()) {
                        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 10_000_000 else { continue }
                        let song = try MODCodec.decode(Data(contentsOf:url))
                        for s in song.samples where !s.pcm.isEmpty {
                            if bytes+s.pcm.count > 64_000_000 || entries.count >= 2500 { break }
                            entries.append(PresetEntry(name:s.name,bank:song.title,source:url.lastPathComponent,sample:s)); bytes += s.pcm.count
                        }
                    } else {
                        let sample = try SampleAudio.load(url).0
                        if bytes+sample.pcm.count > 64_000_000 || entries.count >= 2500 { break }
                        entries.append(PresetEntry(name:sample.name,bank:bank,source:url.lastPathComponent,sample:sample)); bytes += sample.pcm.count
                    }
                } catch { failures += 1 }
            }
            for (i,url) in urls.enumerated() where scopes[i] { url.stopAccessingSecurityScopedResource() }
            let loaded = entries, skipped = failures
            DispatchQueue.main.async {
                self.appendPresets(loaded); self.libraryImporting = false
                self.status = "\(loaded.count) Presets importiert · \(skipped) Dateien übersprungen"
            }
        }
    }
}
