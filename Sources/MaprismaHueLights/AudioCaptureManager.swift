import AppKit
import Foundation
import HueCore
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreAudio)
import CoreAudio
#endif
#if canImport(CoreMedia)
import CoreMedia
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

enum AudioCaptureSource: String, CaseIterable, Identifiable, Equatable, Sendable {
    case systemAudio
    case microphone
    case demoBeat

    var id: String { rawValue }
}

enum AudioPermissionKind: Equatable, Sendable {
    case screenRecording
    case microphone
}

/// App Sandbox-safe audio capture for the Light Synthesizer:
/// - System / streamed audio via `ScreenCaptureKit` (`SCStream`, macOS 13+)
/// - Optional microphone via `AVAudioEngine`
/// - Built-in `DemoBeatGenerator` for Demo Mode & Apple App Review
/// Audio samples are analyzed strictly in memory and never recorded or transmitted.
@MainActor
final class AudioCaptureManager {
    var onLevels: ((AudioBandLevels) -> Void)?
    var onPermissionError: ((AudioPermissionKind, String) -> Void)?

    private let audioQueue = DispatchQueue(label: "com.maprisma.lights.audio")
    private let analyzer = AudioAnalyzer(fftSize: 1024)
    private var demoTask: Task<Void, Never>?

    #if canImport(ScreenCaptureKit)
    private var scStream: SCStream?
    private var scOutput: SCStreamAudioReceiver?
    #endif

    #if canImport(AVFoundation)
    private var audioEngine: AVAudioEngine?
    #endif

    private(set) var isCapturing = false

    func start(source: AudioCaptureSource) async -> Bool {
        stop()
        analyzer.reset()
        switch source {
        case .demoBeat:
            startDemoBeat()
            isCapturing = true
            return true
        case .systemAudio:
            let ok = await startSystemAudio()
            isCapturing = ok
            return ok
        case .microphone:
            let ok = await startMicrophone()
            isCapturing = ok
            return ok
        }
    }

    func stop() {
        isCapturing = false
        demoTask?.cancel()
        demoTask = nil

        #if canImport(ScreenCaptureKit)
        if let stream = scStream {
            scStream = nil
            scOutput = nil
            Task {
                try? await stream.stopCapture()
            }
        }
        #endif

        #if canImport(AVFoundation)
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        #endif
    }

    static func openPrivacySettings(for kind: AudioPermissionKind) {
        let urlString: String
        switch kind {
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Demo Beat

    private func startDemoBeat() {
        let generator = DemoBeatGenerator(bpm: 120.0)
        let startedAt = Date()
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                let levels = generator.sample(at: elapsed)
                await MainActor.run { [weak self] in
                    self?.onLevels?(levels)
                }
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 Hz
            }
        }
    }

    // MARK: - System Audio (ScreenCaptureKit, macOS 13+ MAS compliant)

    private func startSystemAudio() async -> Bool {
        #if canImport(ScreenCaptureKit)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                onPermissionError?(.screenRecording, "No display available for system audio capture.")
                return false
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            // Minimal video dimensions required by macOS 13 SCStream display filter
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let receiver = SCStreamAudioReceiver(analyzer: analyzer) { [weak self] levels in
                Task { @MainActor [weak self] in
                    self?.onLevels?(levels)
                }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
            try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
            self.scOutput = receiver
            self.scStream = stream
            return true
        } catch {
            onPermissionError?(.screenRecording, error.localizedDescription)
            return false
        }
        #else
        onPermissionError?(.screenRecording, "ScreenCaptureKit is unavailable on this platform.")
        return false
        #endif
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicrophone() async -> Bool {
        #if canImport(AVFoundation)
        let granted: Bool = await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    continuation.resume(returning: ok)
                }
            default:
                continuation.resume(returning: false)
            }
        }
        guard granted else {
            onPermissionError?(.microphone, "Microphone permission denied.")
            return false
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            onPermissionError?(.microphone, "No microphone input available.")
            return false
        }

        let localAnalyzer = self.analyzer
        let queue = self.audioQueue
        let sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
            queue.async {
                let levels = localAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
                Task { @MainActor [weak self] in
                    self?.onLevels?(levels)
                }
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
            return true
        } catch {
            input.removeTap(onBus: 0)
            onPermissionError?(.microphone, error.localizedDescription)
            return false
        }
        #else
        onPermissionError?(.microphone, "AVFoundation is unavailable.")
        return false
        #endif
    }
}

#if canImport(ScreenCaptureKit)
private final class SCStreamAudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let analyzer: AudioAnalyzer
    private let callback: (AudioBandLevels) -> Void

    init(analyzer: AudioAnalyzer, callback: @escaping (AudioBandLevels) -> Void) {
        self.analyzer = analyzer
        self.callback = callback
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        var sampleRate = 48000.0
        if let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
           asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }

        var sizeNeeded: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard let first = buffers.first, let dataPtr = first.mData else { return }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: dataPtr.assumingMemoryBound(to: Float.self), count: count))
        let levels = analyzer.analyze(samples: samples, sampleRate: sampleRate)
        callback(levels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stream stopped externally; user can restart from Synth tab.
    }
}
#endif
