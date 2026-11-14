// pattern: Imperative Shell
// Content hashing via swift-crypto. Streaming so large PDFs never sit fully
// in memory; the seam lets tests substitute deterministic digests.

import Crypto
import Foundation

public protocol ContentHashing: Sendable {
    func sha256Hex(fileAt url: URL) throws -> String
    func sha256Hex(of data: Data) -> String
}

public struct SHA256Hasher: ContentHashing {
    public init() {}

    public func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString()
    }

    public func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).hexString()
    }
}

extension SHA256.Digest {
    func hexString() -> String {
        withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }
}
