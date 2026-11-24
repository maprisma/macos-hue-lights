import Foundation

/// A single resource delta extracted from a Philips Hue CLIP v2 `/eventstream/clip/v2` event.
public struct HueSSEUpdate: Equatable, Sendable {
    /// "update", "add", or "delete"
    public let eventType: String
    /// "light", "grouped_light", "scene", "behavior_instance", etc.
    public let resourceType: String
    public let resourceID: String
    public let on: Bool?
    public let brightness: Double?
    public let colorHex: String?
    public let mirek: Int?
    public let effect: String?
    public let sceneActive: Bool?
    public let name: String?

    public init(
        eventType: String,
        resourceType: String,
        resourceID: String,
        on: Bool? = nil,
        brightness: Double? = nil,
        colorHex: String? = nil,
        mirek: Int? = nil,
        effect: String? = nil,
        sceneActive: Bool? = nil,
        name: String? = nil
    ) {
        self.eventType = eventType
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.on = on
        self.brightness = brightness
        self.colorHex = colorHex
        self.mirek = mirek
        self.effect = effect
        self.sceneActive = sceneActive
        self.name = name
    }
}

/// Incremental Server-Sent Events parser for Hue CLIP v2 `/eventstream/clip/v2`.
/// Pure Swift, bounded memory, safe against partial chunks and CRLF/LF line endings.
public struct SSEParser: Sendable {
    public let maxBufferBytes: Int
    private var lineBuffer = Data()
    private var currentDataLines: [String] = []
    private var currentDataBytes = 0

    public init(maxBufferBytes: Int = 4 * 1024 * 1024) {
        self.maxBufferBytes = maxBufferBytes
    }

    /// Feed raw bytes from an SSE stream; returns all complete `data:` payloads decoded as Hue updates.
    public mutating func feed(_ chunk: Data) -> [HueSSEUpdate] {
        guard !chunk.isEmpty else { return [] }
        lineBuffer.append(chunk)
        var updates: [HueSSEUpdate] = []

        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            var lineData = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            let line = String(data: lineData, encoding: .utf8) ?? ""
            updates.append(contentsOf: processLine(line))
        }

        if lineBuffer.count > maxBufferBytes {
            lineBuffer.removeAll(keepingCapacity: false)
            currentDataLines.removeAll(keepingCapacity: false)
            currentDataBytes = 0
        }
        return updates
    }

    /// Feed a single decoded line (without trailing `\n` or `\r\n`).
    public mutating func feedLine(_ rawLine: String) -> [HueSSEUpdate] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        return processLine(line)
    }

    public mutating func reset() {
        lineBuffer.removeAll(keepingCapacity: false)
        currentDataLines.removeAll(keepingCapacity: false)
        currentDataBytes = 0
    }

    private mutating func processLine(_ line: String) -> [HueSSEUpdate] {
        if line.isEmpty {
            guard !currentDataLines.isEmpty else { return [] }
            let payload = currentDataLines.joined(separator: "\n")
            currentDataLines.removeAll(keepingCapacity: true)
            currentDataBytes = 0
            return Self.parsePayload(payload)
        }
        if line.hasPrefix(":") {
            return [] // SSE comment / keepalive
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
            if currentDataBytes + value.utf8.count <= maxBufferBytes {
                currentDataLines.append(value)
                currentDataBytes += value.utf8.count
            } else {
                currentDataLines.removeAll(keepingCapacity: false)
                currentDataBytes = 0
            }
        }
        return []
    }

    /// Parses one Hue CLIP v2 SSE JSON payload (an array of event envelopes).
    public static func parsePayload(_ payload: String) -> [HueSSEUpdate] {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var results: [HueSSEUpdate] = []
        for envelope in root {
            let eventType = (envelope["type"] as? String) ?? "update"
            guard let items = envelope["data"] as? [[String: Any]] else { continue }
            for item in items {
                guard let rtype = item["type"] as? String,
                      let rid = item["id"] as? String,
                      HueColorMath.validUUID(rid) else { continue }

                let on = (item["on"] as? [String: Any])?["on"] as? Bool
                let bri = (item["dimming"] as? [String: Any]).flatMap {
                    HueColorMath.finite($0["brightness"], low: 0.0, high: 100.0)
                }

                let ct = item["color_temperature"] as? [String: Any]
                let mirek = ct.flatMap { JSONValue.optionalInt($0, "mirek") }
                var colorHex: String? = nil
                if let ct = ct, (ct["mirek_valid"] as? Bool) == true, let m = mirek, m > 0 {
                    colorHex = HueColorMath.mirekToHex(m)
                } else if let xy = (item["color"] as? [String: Any])?["xy"] as? [String: Any],
                          let x = HueColorMath.finite(xy["x"], low: 0.0, high: 1.0),
                          let y = HueColorMath.finite(xy["y"], low: 0.0, high: 1.0) {
                    colorHex = HueColorMath.xyToHex(x: x, y: y)
                } else if let m = mirek, m > 0 {
                    colorHex = HueColorMath.mirekToHex(m)
                }

                let effect = (item["effects"] as? [String: Any])?["status"] as? String
                let rawName = (item["metadata"] as? [String: Any])?["name"] as? String
                let cleanName = rawName.map { HueColorMath.clean($0, limit: 60) }.flatMap { $0.isEmpty ? nil : $0 }
                var sceneActive: Bool? = nil
                if rtype == "scene", let status = (item["status"] as? [String: Any])?["active"] as? String {
                    sceneActive = (status != "inactive")
                }

                results.append(HueSSEUpdate(
                    eventType: eventType,
                    resourceType: rtype,
                    resourceID: rid,
                    on: on,
                    brightness: bri,
                    colorHex: colorHex,
                    mirek: mirek,
                    effect: effect,
                    sceneActive: sceneActive,
                    name: cleanName
                ))
            }
        }
        return results
    }
}
