import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Frequency band energy levels (normalized `0...1`) and beat onset flag.
public struct AudioBandLevels: Equatable, Sendable {
    public let bass: Double
    public let mids: Double
    public let treble: Double
    public let energy: Double
    public let isBeat: Bool

    public static let zero = AudioBandLevels(bass: 0, mids: 0, treble: 0, energy: 0, isBeat: false)

    public init(bass: Double, mids: Double, treble: Double, energy: Double, isBeat: Bool) {
        self.bass = HueColorMath.clamp(bass, 0.0, 1.0)
        self.mids = HueColorMath.clamp(mids, 0.0, 1.0)
        self.treble = HueColorMath.clamp(treble, 0.0, 1.0)
        self.energy = HueColorMath.clamp(energy, 0.0, 1.0)
        self.isBeat = isBeat
    }
}

public enum SynthMode: String, CaseIterable, Identifiable, Equatable, Hashable, Codable, Sendable {
    case pulse
    case colorWave
    case club
    case chillAmbient

    public var id: String { rawValue }
}

public enum SynthBand: String, CaseIterable, Identifiable, Equatable, Hashable, Codable, Sendable {
    case bass
    case mids
    case treble
    case all

    public var id: String { rawValue }
}

public enum SynthPalette: String, CaseIterable, Identifiable, Equatable, Hashable, Codable, Sendable {
    case neon
    case sunset
    case ocean
    case fire
    case forest
    case rainbow

    public var id: String { rawValue }

    /// 3-stop hex palette [low/bass, mid, high/treble].
    public var colors: [String] {
        switch self {
        case .neon: return ["#ff2e93", "#9b5de5", "#00f0ff"]
        case .sunset: return ["#ff4d6d", "#ff7b00", "#ffd166"]
        case .ocean: return ["#023e8a", "#0096c7", "#90e0ef"]
        case .fire: return ["#d00000", "#f48c06", "#ffea00"]
        case .forest: return ["#1b4332", "#40916c", "#b7e4c7"]
        case .rainbow: return ["#ff3b30", "#34c759", "#007aff"]
        }
    }
}

/// Per-light frame produced by `SynthFrameMapper` for either CLIP v2 Fast Sync or Hue Entertainment v2.
public struct SynthLightFrame: Equatable, Sendable {
    public let lightID: String
    public let hex: String
    public let xyX: Double
    public let xyY: Double
    public let brightness: Int
    public let r16: UInt16
    public let g16: UInt16
    public let b16: UInt16

    public init(
        lightID: String,
        hex: String,
        xyX: Double,
        xyY: Double,
        brightness: Int,
        r16: UInt16,
        g16: UInt16,
        b16: UInt16
    ) {
        self.lightID = lightID
        self.hex = hex
        self.xyX = xyX
        self.xyY = xyY
        self.brightness = HueColorMath.clamp(brightness, 1, 100)
        self.r16 = r16
        self.g16 = g16
        self.b16 = b16
    }
}

/// Real-time audio spectrum analyzer using Accelerate `vDSP_fft_zrip` on Apple platforms
/// (and a pure-Swift DFT fallback on non-Apple platforms). Splits PCM float samples into
/// Bass (20–250 Hz), Mids (250–2000 Hz), and Treble (2000–16000 Hz) plus rolling-energy beat detection.
public final class AudioAnalyzer {
    public let fftSize: Int
    private let log2n: UInt
    private var energyHistory: [Double] = []
    private let historyLimit = 24
    private var lastBeatTime: Date = .distantPast
    private let beatCooldown: TimeInterval = 0.14
    private let now: () -> Date

    #if canImport(Accelerate)
    private let fftSetup: FFTSetup?
    private var window: [Float]
    #endif

    public init(fftSize: Int = 1024, now: @escaping () -> Date = Date.init) {
        let clamped = fftSize >= 64 ? (1 << Int(log2(Double(fftSize)))) : 64
        self.fftSize = clamped
        self.log2n = UInt(log2(Double(clamped)))
        self.now = now
        #if canImport(Accelerate)
        self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))
        var w = [Float](repeating: 0, count: clamped)
        vDSP_hann_window(&w, vDSP_Length(clamped), Int32(vDSP_HANN_NORM))
        self.window = w
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
        #endif
    }

    public func reset() {
        energyHistory.removeAll(keepingCapacity: true)
        lastBeatTime = .distantPast
    }

    public func analyze(samples: [Float], sampleRate: Double = 48000.0) -> AudioBandLevels {
        guard !samples.isEmpty, sampleRate > 0 else { return .zero }

        var frame = [Float](repeating: 0, count: fftSize)
        let copyCount = min(samples.count, fftSize)
        let startIdx = samples.count - copyCount
        for i in 0..<copyCount {
            frame[i] = samples[startIdx + i]
        }

        let magnitudes = computeMagnitudes(frame: &frame)
        let binHz = sampleRate / Double(fftSize)
        let halfCount = magnitudes.count

        func bandAverage(lowHz: Double, highHz: Double) -> Double {
            let lo = max(1, Int(floor(lowHz / binHz)))
            let hi = min(halfCount - 1, Int(ceil(highHz / binHz)))
            guard hi >= lo else { return 0 }
            var sum = 0.0
            for i in lo...hi {
                sum += Double(magnitudes[i])
            }
            let avg = sum / Double(hi - lo + 1)
            // Log-compressed normalization into 0...1 for responsive visual meters
            return HueColorMath.clamp(log1p(avg * 6.0) / log1p(6.0), 0.0, 1.0)
        }

        let bass = bandAverage(lowHz: 20, highHz: 250)
        let mids = bandAverage(lowHz: 250, highHz: 2000)
        let treble = bandAverage(lowHz: 2000, highHz: min(16000, sampleRate * 0.48))
        let energy = HueColorMath.clamp(bass * 0.55 + mids * 0.30 + treble * 0.15, 0.0, 1.0)

        let avgEnergy = energyHistory.isEmpty ? energy : (energyHistory.reduce(0, +) / Double(energyHistory.count))
        let currentTime = now()
        let isBeat = energyHistory.count >= 4
            && energy > max(0.08, avgEnergy * 1.45)
            && currentTime.timeIntervalSince(lastBeatTime) >= beatCooldown
        if isBeat {
            lastBeatTime = currentTime
        }

        energyHistory.append(energy)
        if energyHistory.count > historyLimit {
            energyHistory.removeFirst(energyHistory.count - historyLimit)
        }

        return AudioBandLevels(bass: bass, mids: mids, treble: treble, energy: energy, isBeat: isBeat)
    }

    private func computeMagnitudes(frame: inout [Float]) -> [Float] {
        let halfN = fftSize / 2
        #if canImport(Accelerate)
        guard let setup = fftSetup else { return [Float](repeating: 0, count: halfN) }
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                frame.withUnsafeBytes { rawBytes in
                    let complexPtr = rawBytes.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(halfN))
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(halfN))
            }
        }
        var scale = 1.0 / Float(fftSize)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfN))
        return mags
        #else
        // Pure-Swift Hann-windowed DFT fallback for non-Apple unit test environments.
        let n = fftSize
        var windowed = [Double](repeating: 0, count: n)
        let twoPi = 2.0 * Double.pi
        for i in 0..<n {
            let w = 0.5 * (1.0 - cos(twoPi * Double(i) / Double(max(1, n - 1))))
            windowed[i] = Double(frame[i]) * w
        }
        var mags = [Float](repeating: 0, count: halfN)
        let invN = 2.0 / Double(n)
        for k in 0..<halfN {
            var re = 0.0
            var im = 0.0
            let angleStep = twoPi * Double(k) / Double(n)
            for i in 0..<n {
                let a = angleStep * Double(i)
                re += windowed[i] * cos(a)
                im -= windowed[i] * sin(a)
            }
            mags[k] = Float(sqrt(re * re + im * im) * invN)
        }
        return mags
        #endif
    }
}

/// Deterministic mapper from audio band levels to per-light Hue color & brightness frames.
public final class SynthFrameMapper {
    private var smoothedBrightness: [String: Double] = [:]
    private var smoothedHueT: [String: Double] = [:]
    private var beatFlash: Double = 0.0

    public init() {}

    public func reset() {
        smoothedBrightness.removeAll()
        smoothedHueT.removeAll()
        beatFlash = 0.0
    }

    public func map(
        lightID: String,
        lightIndex: Int,
        levels: AudioBandLevels,
        mode: SynthMode,
        palette: SynthPalette,
        band: SynthBand,
        sensitivity: Double,
        smoothness: Double,
        phase: Double
    ) -> SynthLightFrame {
        let sens = HueColorMath.clamp(sensitivity, 0.3, 2.5)
        let smooth = HueColorMath.clamp(smoothness, 0.0, 0.92)
        let alpha = 1.0 - smooth

        let rawBand: Double
        switch band {
        case .bass: rawBand = levels.bass
        case .mids: rawBand = levels.mids
        case .treble: rawBand = levels.treble
        case .all: rawBand = levels.energy
        }

        let boosted = HueColorMath.clamp(rawBand * sens, 0.0, 1.0)
        if levels.isBeat {
            beatFlash = 1.0
        } else {
            beatFlash *= 0.72
        }

        let targetBri: Double
        let targetT: Double

        switch mode {
        case .pulse:
            targetBri = 12.0 + boosted * 78.0 + (levels.isBeat ? 10.0 : 0.0)
            targetT = HueColorMath.clamp(levels.treble * 0.6 + levels.mids * 0.4, 0.0, 1.0)
        case .colorWave:
            let wave = 0.5 + 0.5 * sin(phase * 1.4 + Double(lightIndex) * 0.85)
            targetBri = 25.0 + boosted * 65.0
            targetT = HueColorMath.clamp(wave * 0.65 + levels.mids * 0.35, 0.0, 1.0)
        case .club:
            let flash = beatFlash * (lightIndex % 2 == 0 ? 1.0 : 0.6)
            targetBri = 8.0 + max(boosted * 85.0, flash * 92.0)
            let cycle = fmod(phase * 0.6 + Double(lightIndex) * 0.33 + (levels.isBeat ? 0.35 : 0.0), 1.0)
            targetT = abs(cycle)
        case .chillAmbient:
            let drift = 0.5 + 0.5 * sin(phase * 0.35 + Double(lightIndex) * 0.5)
            targetBri = 22.0 + boosted * 42.0
            targetT = HueColorMath.clamp(drift * 0.75 + levels.bass * 0.25, 0.0, 1.0)
        }

        let prevBri = smoothedBrightness[lightID] ?? targetBri
        let bri = prevBri + (targetBri - prevBri) * alpha
        smoothedBrightness[lightID] = bri

        let prevT = smoothedHueT[lightID] ?? targetT
        let t = prevT + (targetT - prevT) * alpha
        smoothedHueT[lightID] = t

        let (r, g, b) = Self.samplePalette(palette, t: t)
        let hex = String(
            format: "#%02x%02x%02x",
            HueColorMath.clamp(Int((r * 255.0).rounded()), 0, 255),
            HueColorMath.clamp(Int((g * 255.0).rounded()), 0, 255),
            HueColorMath.clamp(Int((b * 255.0).rounded()), 0, 255)
        )
        let xy = HueColorMath.hexToXY(hex) ?? (0.3127, 0.3290)
        let briFrac = HueColorMath.clamp(bri / 100.0, 0.05, 1.0)
        let r16 = UInt16(HueColorMath.clamp(Int((r * briFrac * 65535.0).rounded()), 0, 65535))
        let g16 = UInt16(HueColorMath.clamp(Int((g * briFrac * 65535.0).rounded()), 0, 65535))
        let b16 = UInt16(HueColorMath.clamp(Int((b * briFrac * 65535.0).rounded()), 0, 65535))

        return SynthLightFrame(
            lightID: lightID,
            hex: hex,
            xyX: xy.x,
            xyY: xy.y,
            brightness: HueColorMath.clamp(Int(bri.rounded()), 1, 100),
            r16: r16,
            g16: g16,
            b16: b16
        )
    }

    private static func samplePalette(_ palette: SynthPalette, t: Double) -> (Double, Double, Double) {
        let stops = palette.colors.map(rgb)
        guard stops.count >= 2 else {
            let c = stops.first ?? (1.0, 0.8, 0.5)
            return (c.r, c.g, c.b)
        }
        let clamped = HueColorMath.clamp(t, 0.0, 1.0)
        let scaled = clamped * Double(stops.count - 1)
        let idx = min(stops.count - 2, Int(floor(scaled)))
        let frac = scaled - Double(idx)
        let a = stops[idx]
        let b = stops[idx + 1]
        return (
            a.r + (b.r - a.r) * frac,
            a.g + (b.g - a.g) * frac,
            a.b + (b.b - a.b) * frac
        )
    }
}

/// Synthetic 120 BPM electronic beat generator for Demo Mode & Apple App Review
/// (lets users test the Light Synthesizer live without audio hardware or screen permissions).
public struct DemoBeatGenerator: Sendable {
    public var bpm: Double

    public init(bpm: Double = 120.0) {
        self.bpm = bpm
    }

    public func sample(at elapsedSeconds: Double) -> AudioBandLevels {
        let beatsPerSec = bpm / 60.0
        let beatPos = elapsedSeconds * beatsPerSec
        let frac = beatPos - floor(beatPos)
        let beatIndex = Int(floor(beatPos)) % 4

        // Punchy four-on-the-floor kick envelope
        let kick = exp(-frac * 7.5)
        // Snare / synth mids on beats 1 and 3
        let snare = (beatIndex == 1 || beatIndex == 3) ? exp(-frac * 6.0) * 0.85 : 0.25 + 0.2 * sin(elapsedSeconds * 3.1)
        // Hi-hat & shimmer treble on eighth notes
        let eighthFrac = (beatPos * 2.0) - floor(beatPos * 2.0)
        let treble = 0.2 + 0.7 * exp(-eighthFrac * 9.0) * (0.65 + 0.35 * sin(elapsedSeconds * 5.3))

        let bass = HueColorMath.clamp(0.15 + kick * 0.85, 0.0, 1.0)
        let mids = HueColorMath.clamp(snare, 0.0, 1.0)
        let hi = HueColorMath.clamp(treble, 0.0, 1.0)
        let energy = HueColorMath.clamp(bass * 0.55 + mids * 0.30 + hi * 0.15, 0.0, 1.0)
        let isBeat = frac < 0.11

        return AudioBandLevels(bass: bass, mids: mids, treble: hi, energy: energy, isBeat: isBeat)
    }
}
