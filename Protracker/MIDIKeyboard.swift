import CoreMIDI
import Combine
import Foundation

struct MIDINoteEvent: Equatable {
    var note: Int
    var velocity: Int
    var channel: Int
    var on: Bool
}
/// Running status, real-time bytes and split packets are handled per MIDI source.
struct MIDINoteDecoder {
    private var status: UInt8 = 0
    private var pending: [UInt8] = []
    private var sysex = false
    mutating func decode(_ bytes: [UInt8]) -> [MIDINoteEvent] {
        var events: [MIDINoteEvent] = []
        for byte in bytes {
            if byte >= 0xf8 { continue }
            if byte == 0xf0 { sysex = true; status = 0; pending = []; continue }
            if byte == 0xf7 { sysex = false; continue }
            if sysex { continue }
            if byte >= 0x80 { status = byte < 0xf0 ? byte : 0; pending = []; continue }
            guard status != 0 else { continue }
            pending.append(byte)
            let command = status & 0xf0, length = command == 0xc0 || command == 0xd0 ? 1 : 2
            if pending.count == length {
                if command == 0x90 || command == 0x80 {
                    events.append(MIDINoteEvent(note:Int(pending[0]),velocity:Int(pending[1]),channel:Int(status&15),on:command == 0x90 && pending[1] > 0))
                }
                pending = []
            }
        }
        return events
    }
}
private final class MIDIDecoderBank: @unchecked Sendable {
    let lock = NSLock()
    var decoders: [Int:MIDINoteDecoder] = [:]
    func decode(source: Int, bytes: [UInt8]) -> [MIDINoteEvent] {
        lock.lock(); defer { lock.unlock() }
        var decoder = decoders[source] ?? MIDINoteDecoder()
        let events = decoder.decode(bytes); decoders[source] = decoder; return events
    }
}
@MainActor
final class MIDIKeyboard: ObservableObject {
    @Published var status: AppText = "MIDI disabled"
    @Published var sources: [String] = []
    var onNote: ((MIDINoteEvent) -> Void)?
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var endpoints: [MIDIEndpointRef] = []
    private let decoder = MIDIDecoderBank()
    private var enabled = false
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value { close(); return }
        let result = MIDIClientCreateWithBlock("Protracker" as CFString,&client) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        guard result == noErr else { enabled = false; status = "MIDI client error \(result)"; return }
        let bank = decoder
        let inputResult = MIDIInputPortCreateWithBlock(client,"Tracker keyboard" as CFString,&port) { [weak self] list, source in
            let id = source.map { Int(bitPattern:$0) } ?? 0
            let offset = MemoryLayout<MIDIPacketList>.offset(of:\.packet)!
            var pointer = UnsafeRawPointer(list).advanced(by:offset).assumingMemoryBound(to:MIDIPacket.self)
            var events: [MIDINoteEvent] = []
            for _ in 0..<list.pointee.numPackets {
                let packet = pointer.pointee
                let dataOffset = MemoryLayout<MIDIPacket>.offset(of:\.data)!
                let data = UnsafeRawPointer(pointer).advanced(by:dataOffset).assumingMemoryBound(to:UInt8.self)
                let bytes = Array(UnsafeBufferPointer(start:data,count:Int(packet.length)))
                events += bank.decode(source:id,bytes:bytes)
                pointer = UnsafePointer(MIDIPacketNext(pointer))
            }
            let notes = events
            DispatchQueue.main.async { for note in notes { self?.onNote?(note) } }
        }
        guard inputResult == noErr else { close(); status = "MIDI input error \(inputResult)"; return }
        refresh()
    }
    private func refresh() {
        guard enabled && port != 0 else { return }
        for endpoint in endpoints { MIDIPortDisconnectSource(port,endpoint) }
        endpoints = []; sources = []
        for i in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(i)
            if MIDIPortConnectSource(port,endpoint,UnsafeMutableRawPointer(bitPattern:Int(endpoint))) == noErr {
                endpoints.append(endpoint)
                var value: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&value)
                sources.append(value?.takeRetainedValue() as String? ?? "MIDI \(i+1)")
            }
        }
        status = sources.isEmpty ? "No MIDI input connected" : .verbatim(sources.joined(separator:", "))
    }
    func close() {
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        endpoints = []; sources = []; enabled = false; status = "MIDI disabled"
    }
}
