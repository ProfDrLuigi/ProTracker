import AVFoundation
import Combine

private final class CaptureStartToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
private final class RecorderBox: @unchecked Sendable {
    let value: AVAudioRecorder
    init(_ value: AVAudioRecorder) { self.value = value }
}

/// Microphone activation is explicit. Slow device drivers never block the editor.
@MainActor
final class SampleRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var recording = false
    @Published var starting = false
    @Published var deviceBusy = false
    @Published var level: Float = 0
    @Published var seconds: Double = 0
    @Published var message: AppText = "Aufnahme über das Standard-Audioeingabegerät deines Mac."
    @Published var hasTake = false
    private var recorder: RecorderBox?
    private var takeURL: URL?
    private var timer: AnyCancellable?
    private var pending: CaptureStartToken?
    private var permissionRequestID: UUID?
    private let queue = DispatchQueue(label:"Protracker.capture",qos:.userInitiated)
    let limit = 131070.0 / SampleAudio.rootRate
    func start() {
        guard !recording && !starting && !deviceBusy else { return }
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: begin()
        case .notDetermined:
            let id = UUID(); permissionRequestID = id; starting = true
            message = "Mikrofonfreigabe wird angefragt …"
            AVCaptureDevice.requestAccess(for:.audio) { granted in
                DispatchQueue.main.async {
                    guard self.permissionRequestID == id else { return }
                    self.permissionRequestID = nil; self.starting = false
                    if granted { self.begin() } else { self.message = "Mikrofonzugriff wurde nicht erlaubt." }
                }
            }
        default: message = "Mikrofonzugriff in Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon erlauben."
        }
    }
    private func begin() {
        guard !recording && !starting && !deviceBusy else { return }
        if let takeURL { try? FileManager.default.removeItem(at:takeURL) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("protracker-take-\(UUID().uuidString).wav")
        let token = CaptureStartToken(), duration = limit
        pending = token; starting = true; deviceBusy = true; hasTake = false; seconds = 0
        takeURL = url; message = "Audioeingabe wird gestartet …"
        let settings: [String:Any] = [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:SampleAudio.rootRate,
            AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false]
        DispatchQueue.main.asyncAfter(deadline:.now()+5) {
            guard self.pending === token else { return }
            token.cancel(); self.pending = nil; self.starting = false
            self.message = "Das Audioeingabegerät antwortet nicht. Bitte das Eingabegerät in macOS prüfen."
        }
        let captureQueue = queue
        captureQueue.async {
            let result: Result<RecorderBox,Error> = Result {
                let box = RecorderBox(try AVAudioRecorder(url:url,settings:settings))
                guard !token.isCancelled else { throw CancellationError() }
                guard box.value.prepareToRecord() else { throw ModuleError.invalid("Audioeingabe konnte nicht vorbereitet werden.") }
                guard !token.isCancelled else { throw CancellationError() }
                guard box.value.record(forDuration:duration) else { throw ModuleError.invalid("Audioaufnahme konnte nicht gestartet werden.") }
                return box
            }
            DispatchQueue.main.async {
                guard self.pending === token && !token.isCancelled else {
                    // Release the device before allowing another take to start.
                    if case .success(let box) = result {
                        captureQueue.async { box.value.stop(); DispatchQueue.main.async { self.deviceBusy = false } }
                    } else { self.deviceBusy = false }
                    return
                }
                self.pending = nil; self.starting = false; self.deviceBusy = false
                switch result {
                case .success(let box):
                    self.recorder = box; box.value.delegate = self; box.value.isMeteringEnabled = true; self.recording = true
                    self.message = "Aufnahme läuft · maximal \(String(format:"%.1f",duration)) Sekunden"
                    self.timer = Timer.publish(every:0.05,on:.main,in:.common).autoconnect().sink { [weak self] _ in
                        guard let self, let rec = self.recorder?.value else { return }
                        rec.updateMeters(); self.level = pow(10,rec.averagePower(forChannel:0)/20); self.seconds = rec.currentTime
                    }
                case .failure(let error): self.message = .verbatim(error.localizedDescription)
                }
            }
        }
    }
    func stop() { finish(success:true) }
    private func finish(success: Bool) {
        let wasStarting = starting
        permissionRequestID = nil; pending?.cancel(); pending = nil; starting = false
        timer?.cancel(); timer = nil; recording = false; level = 0
        guard let box = recorder else {
            if wasStarting { message = "Aufnahmestart abgebrochen." }
            return
        }
        recorder = nil; hasTake = false; deviceBusy = true
        message = "Aufnahme wird abgeschlossen …"
        queue.async {
            box.value.stop()
            DispatchQueue.main.async {
                self.deviceBusy = false; self.hasTake = success
                self.message = success ? "Aufnahme bereit · Übernehmen lädt sie in den gewählten Sample-Platz." : "Aufnahme wurde unterbrochen."
            }
        }
    }

    func take() throws -> TrackerSample {
        guard hasTake && !recording && !starting, let takeURL else { throw ModuleError.invalid("Keine abgeschlossene Aufnahme vorhanden.") }
        var sample = try SampleAudio.load(takeURL).0; sample.name = "Recorded sample"; return sample
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { if self.recorder?.value === recorder { self.finish(success:flag) } }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async { if self.recorder?.value === recorder { self.finish(success:false) } }
    }
}
