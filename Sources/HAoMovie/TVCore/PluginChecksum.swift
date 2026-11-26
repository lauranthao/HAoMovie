import CryptoKit
import Foundation

/// The hex SHA-256 of data, used for short stable tags and cache file names.
public enum PluginChecksum {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
