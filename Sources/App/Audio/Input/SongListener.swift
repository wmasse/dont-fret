import Foundation
import CoreAudio
import AVFoundation
import AppKit

// Whole-song listening for songs with no chord chart: the user plays the song on their Mac
// (Spotify, Music, YouTube…) and Don't Fret listens to the Mac's sound output through a
// Core Audio process tap (macOS 14.2+). Nothing is saved — the audio is analysed in memory.

enum ListenError: LocalizedError {
    case unsupported, tapFailed(OSStatus), deviceFailed(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Listening to your Mac's sound needs macOS 14.2 or later. You can choose an audio file instead."
        case .tapFailed(let s): return "Couldn't start listening to your Mac's sound (error \(s))."
        case .deviceFailed(let s): return "Couldn't start listening to your Mac's sound (device error \(s))."
        }
    }
}

/// Captures everything the Mac plays (except this app) as mono samples.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.dontfret.listen", qos: .userInitiated)
    private let lock = NSLock()
    private var samples: [Float] = []
    /// (L − R) / 2, kept so the melody finder can tell the centre (lead vocal) from the sides.
    private var side: [Float] = []
    private var lastRMS: Float = 0
    private(set) var sampleRate: Double = 48000

    init() throws {
        // 1. a tap on all system audio except our own process
        var exclude: [AudioObjectID] = []
        if let me = Self.processObject(pid: getpid()) { exclude.append(me) }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "Don't Fret listening"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw ListenError.tapFailed(err) }

        // 2. the tap's audio format
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt)
        guard err == noErr else { cleanup(); throw ListenError.tapFailed(err) }
        sampleRate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48000
        let channels = Int(max(1, fmt.mChannelsPerFrame))
        let interleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        // room for about seven minutes up front, so the audio thread rarely has to grow the buffer
        samples.reserveCapacity(Int(sampleRate * 420))
        if channels >= 2 { side.reserveCapacity(Int(sampleRate * 420)) }

        // 3. a private aggregate device that carries the tap
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Don't Fret Listener",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]
        ]
        if let out = Self.defaultOutputUID() {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = out
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: out]]
        }
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard err == noErr else { cleanup(); throw ListenError.deviceFailed(err) }

        // 4. read audio as it arrives
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var mono: [Float] = []
            var sd: [Float] = []
            if interleaved, let b = list.first, let data = b.mData {
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size / channels
                let p = data.assumingMemoryBound(to: Float.self)
                mono = (0..<n).map { i in
                    var s: Float = 0
                    for c in 0..<channels { s += p[i * channels + c] }
                    return s / Float(channels)
                }
                if channels >= 2 { sd = (0..<n).map { i in (p[i * channels] - p[i * channels + 1]) * 0.5 } }
            } else if !interleaved {
                let bufs = list.compactMap { b -> UnsafePointer<Float>? in b.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) } }
                guard let first = list.first, !bufs.isEmpty else { return }
                let n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                mono = (0..<n).map { i in bufs.reduce(0) { $0 + $1[i] } / Float(bufs.count) }
                if bufs.count >= 2 { sd = (0..<n).map { i in (bufs[0][i] - bufs[1][i]) * 0.5 } }
            }
            guard !mono.isEmpty else { return }
            let rms = sqrt(mono.reduce(0) { $0 + $1 * $1 } / Float(mono.count))
            self.lock.lock()
            self.samples.append(contentsOf: mono)
            if sd.count == mono.count { self.side.append(contentsOf: sd) }
            self.lastRMS = rms
            self.lock.unlock()
        }
        guard err == noErr, let procID else { cleanup(); throw ListenError.deviceFailed(err) }
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { cleanup(); throw ListenError.deviceFailed(err) }
    }

    /// Seconds captured so far and the current loudness (0–1).
    var status: (seconds: Double, level: Float) {
        lock.lock(); defer { lock.unlock() }
        return (Double(samples.count) / sampleRate, lastRMS)
    }

    /// Stops listening and hands back the audio: mid, and side when it was stereo throughout.
    func finish() -> (mono: [Float], side: [Float]?) {
        cleanup()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        let sd = side.count == samples.count ? side : nil
        samples = []
        side = []
        return (out, sd)
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { cleanup() }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return err == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    private static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid?.takeRetainedValue() else { return nil }
        return u as String
    }
}

/// Drives a whole-song listen: start, show progress, stop, analyse.
@MainActor
@Observable
final class WholeSongListener {
    enum Stage: Equatable { case idle, listening, analysing, done, failed(String) }
    private(set) var stage: Stage = .idle
    private(set) var seconds: Double = 0
    private(set) var level: Float = 0
    /// Seconds the song has been audibly playing (for the "nothing heard yet" hint).
    private(set) var heardSeconds: Double = 0
    @ObservationIgnored private var tap: AnyObject?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var target: Double = 0
    @ObservationIgnored private var onResult: ((Transcription) -> Void)?
    @ObservationIgnored private var language: String?
    @ObservationIgnored private var hints: [String] = []

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Starts listening; finishes by itself shortly after `songSeconds`, or when `stop()` is called.
    /// `language` is the lyrics' language, so the sung words can be picked out to line the lyrics up.
    func start(songSeconds: Double?, language: String? = nil, hints: [String] = [], onResult: @escaping (Transcription) -> Void) {
        guard #available(macOS 14.2, *) else { stage = .failed(ListenError.unsupported.localizedDescription); return }
        cancel()
        do {
            let t = try SystemAudioTap()
            tap = t
            self.onResult = onResult
            self.language = language
            self.hints = hints
            target = (songSeconds ?? 0) > 30 ? songSeconds! + 4 : 0
            seconds = 0; heardSeconds = 0; level = 0
            stage = .listening
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't start listening.")
        }
    }

    private func tick() {
        guard #available(macOS 14.2, *), let t = tap as? SystemAudioTap else { return }
        let s = t.status
        seconds = s.seconds
        level = min(1, s.level * 4)
        if s.level > 0.004 { heardSeconds += 0.2 }
        if target > 0 && seconds >= target { stop() }
    }

    /// Stops listening and works out the chords of everything heard.
    func stop() {
        guard #available(macOS 14.2, *), let t = tap as? SystemAudioTap else { return }
        timer?.invalidate(); timer = nil
        let (samples, side) = t.finish()
        let sr = t.sampleRate
        tap = nil
        stage = .analysing
        let done = onResult
        let language = language, hints = hints
        Task.detached(priority: .userInitiated) {
            // skip the silence before the song started and after it ended
            let keep = Self.loudRange(samples)
            do {
                let mono = Array(samples[keep])
                var result = try Transcriber.analyze(samples: mono, side: side.map { Array($0[keep]) }, sampleRate: sr)
                result.heardWords = await WordListener.words(samples: mono, sampleRate: sr, language: language, hints: hints)
                await MainActor.run {
                    self.stage = .done
                    done?(result)
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "Couldn't work out the chords."
                await MainActor.run { self.stage = .failed(msg) }
            }
        }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        if #available(macOS 14.2, *), let t = tap as? SystemAudioTap { _ = t.finish() }
        tap = nil
        stage = .idle
    }

    nonisolated static func trimSilence(_ x: [Float]) -> [Float] { Array(x[loudRange(x)]) }

    /// The part of the audio between the silence before the song and after it.
    nonisolated static func loudRange(_ x: [Float]) -> Range<Int> {
        let block = 4800
        guard x.count > block * 4 else { return 0..<x.count }
        func loud(_ i: Int) -> Bool {
            let end = min(x.count, i + block)
            var s: Float = 0
            for k in i..<end { s += x[k] * x[k] }
            return sqrt(s / Float(end - i)) > 0.004
        }
        var a = 0
        while a + block < x.count && !loud(a) { a += block }
        var b = x.count - block
        while b > a && !loud(b) { b -= block }
        return a..<min(x.count, b + block)
    }

    /// Opens System Settings at the audio recording privacy page.
    static func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") { NSWorkspace.shared.open(u) }
    }
}
