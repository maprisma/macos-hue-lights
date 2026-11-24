import Foundation
#if canImport(Network) && canImport(Security)
import Dispatch
import Network
import Security
#endif

/// A single entertainment channel mapped to one or more Hue lights.
public struct HueEntertainmentChannel: Identifiable, Equatable, Hashable, Sendable {
    public var id: UInt8 { channelID }
    public let channelID: UInt8
    public let lightIDs: [String]

    public init(channelID: UInt8, lightIDs: [String]) {
        self.channelID = channelID
        self.lightIDs = lightIDs
    }
}

/// Parsed CLIP v2 `entertainment_configuration` resource for low-latency DTLS streaming.
public struct HueEntertainmentArea: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let channels: [HueEntertainmentChannel]

    public init(id: String, name: String, channels: [HueEntertainmentChannel]) {
        self.id = id
        self.name = name
        self.channels = channels
    }
}

/// Pure-Swift encoder for Philips Hue Entertainment API v2 binary packets (`HueStream` v2.0).
public enum HueStreamPacket {
    public enum ColorSpace: UInt8, Equatable, Sendable {
        case rgb16 = 0x00
        case xyBri = 0x01
    }

    public struct ChannelValue: Equatable, Sendable {
        public let channelID: UInt8
        public let c1: UInt16
        public let c2: UInt16
        public let c3: UInt16

        public init(channelID: UInt8, c1: UInt16, c2: UInt16, c3: UInt16) {
            self.channelID = channelID
            self.c1 = c1
            self.c2 = c2
            self.c3 = c3
        }
    }

    public static let headerLength = 52
    public static let channelRecordLength = 7
    public static let maxChannels = 20

    /// Encodes a HueStream v2.0 packet:
    /// - 9 bytes `"HueStream"`
    /// - 2 bytes version `0x02, 0x00`
    /// - 1 byte sequence number
    /// - 2 bytes reserved `0x00, 0x00`
    /// - 1 byte color space (`0x00` RGB16 / `0x01` XY+Bri)
    /// - 1 byte reserved `0x00`
    /// - 36 bytes ASCII Entertainment Area UUID
    /// - N × 7 bytes `[channelID(1), c1(2 BE), c2(2 BE), c3(2 BE)]`
    public static func encode(
        areaID: String,
        sequence: UInt8 = 0,
        colorSpace: ColorSpace = .rgb16,
        channels: [ChannelValue]
    ) -> Data {
        let clampedChannels = Array(channels.prefix(maxChannels))
        var data = Data()
        data.reserveCapacity(headerLength + clampedChannels.count * channelRecordLength)

        data.append(contentsOf: "HueStream".utf8)   // 9 bytes
        data.append(0x02)                            // major version 2
        data.append(0x00)                            // minor version 0
        data.append(sequence)                        // sequence number
        data.append(0x00)                            // reserved
        data.append(0x00)                            // reserved
        data.append(colorSpace.rawValue)             // 0x00 = RGB16, 0x01 = XY+Bri
        data.append(0x00)                            // reserved

        // 36-byte ASCII UUID (padded with 0x00 if shorter)
        let uuidBytes = Array(areaID.utf8.prefix(36))
        data.append(contentsOf: uuidBytes)
        if uuidBytes.count < 36 {
            data.append(contentsOf: repeatElement(UInt8(0), count: 36 - uuidBytes.count))
        }

        for ch in clampedChannels {
            data.append(ch.channelID)
            data.append(UInt8((ch.c1 >> 8) & 0xFF))
            data.append(UInt8(ch.c1 & 0xFF))
            data.append(UInt8((ch.c2 >> 8) & 0xFF))
            data.append(UInt8(ch.c2 & 0xFF))
            data.append(UInt8((ch.c3 >> 8) & 0xFF))
            data.append(UInt8(ch.c3 & 0xFF))
        }
        return data
    }

    /// Parses a 32-char hex Hue `clientkey` into 16 raw PSK bytes.
    public static func hexKeyBytes(_ hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 32 else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(16)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return bytes
    }
}

#if canImport(Network) && canImport(Security)
/// Low-latency Hue Entertainment v2 DTLS 1.2 + PSK UDP:2100 streamer.
/// Streams `HueStream` v2.0 packets at ~25 Hz when an entertainment area and `clientKey` are present.
@MainActor
public final class EntertainmentStreamer {
    public private(set) var isStreaming: Bool = false

    private var connection: NWConnection?
    private var areaID: String = ""
    private var sequence: UInt8 = 0
    private let queue = DispatchQueue(label: "com.maprisma.lights.entertainment")

    public init() {}

    /// Opens a DTLS 1.2 PSK UDP:2100 connection to the bridge.
    /// Caller should activate `/clip/v2/resource/entertainment_configuration/<areaID>` (`{"action":"active"}`) first.
    public func start(ip: String, appKey: String, clientKeyHex: String, areaID: String) -> Bool {
        stop()
        guard HueColorMath.validBridgeIP(ip),
              !appKey.isEmpty,
              let pskBytes = HueStreamPacket.hexKeyBytes(clientKeyHex),
              let port = NWEndpoint.Port(rawValue: 2100) else {
            return false
        }

        let tlsOptions = NWProtocolTLS.Options()
        let secOpts = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOpts, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(secOpts, .DTLSv12)
        // TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8) — required by Philips Hue Entertainment API v2
        if let suite = tls_ciphersuite_t(rawValue: 0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(secOpts, suite)
        }

        let pskDispatch = pskBytes.withUnsafeBytes { ptr in
            DispatchData(bytes: ptr) as __DispatchData
        }
        let identityBytes = Data(appKey.utf8)
        let idDispatch = identityBytes.withUnsafeBytes { ptr in
            DispatchData(bytes: ptr) as __DispatchData
        }
        sec_protocol_options_add_pre_shared_key(secOpts, pskDispatch, idDispatch)

        let params = NWParameters(dtls: tlsOptions, udp: NWProtocolUDP.Options())
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: port, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in
                    self?.stop()
                }
            }
        }
        conn.start(queue: queue)

        self.connection = conn
        self.areaID = areaID
        self.sequence = 0
        self.isStreaming = true
        return true
    }

    public func send(channels: [HueStreamPacket.ChannelValue]) {
        guard isStreaming, let conn = connection, !channels.isEmpty else { return }
        sequence &+= 1
        let packet = HueStreamPacket.encode(
            areaID: areaID,
            sequence: sequence,
            colorSpace: .rgb16,
            channels: channels
        )
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        areaID = ""
        isStreaming = false
    }
}
#endif
