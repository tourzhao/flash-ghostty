import Cocoa

/// A wrapper that allows a Swift Codable to implement NSSecureCoding.
class CodableBridge<Wrapped: Codable>: NSObject, NSSecureCoding {
    private var decoded: Wrapped?
    private var encoded: Data?

    /// Retained for compatibility with existing callers that know their
    /// archive is valid. Restoration code should use `decodedValue()` so a
    /// corrupt saved state can be handled without trapping.
    var value: Wrapped {
        guard let value = decodedValue() else {
            preconditionFailure("failed to decode CodableBridge value")
        }

        return value
    }

    init(_ value: Wrapped) {
        self.decoded = value
        self.encoded = nil
    }

    static var supportsSecureCoding: Bool { return true }

    required init?(coder aDecoder: NSCoder) {
        guard let data = aDecoder.decodeObject(of: NSData.self, forKey: "data") else { return nil }

        // Copy the encoded payload while AppKit's outer restoration coder is
        // still valid. Decoding is intentionally deferred because decoding a
        // terminal SurfaceView starts its PTY.
        self.decoded = nil
        self.encoded = Data(data)
    }

    func encode(with aCoder: NSCoder) {
        if let encoded {
            aCoder.encode(encoded as NSData, forKey: "data")
            return
        }

        guard let decoded else { return }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        guard (try? archiver.encodeEncodable(decoded, forKey: "value")) != nil else { return }
        aCoder.encode(archiver.encodedData, forKey: "data")
    }

    /// Decode the wrapped value on demand. A bridge unarchived from AppKit is
    /// therefore a passive, independently-owned snapshot until this is called.
    func decodedValue() -> Wrapped? {
        if let decoded { return decoded }
        guard let encoded,
              let archiver = try? NSKeyedUnarchiver(forReadingFrom: encoded),
              let value = archiver.decodeDecodable(Wrapped.self, forKey: "value") else { return nil }

        decoded = value
        self.encoded = nil
        return value
    }
}
