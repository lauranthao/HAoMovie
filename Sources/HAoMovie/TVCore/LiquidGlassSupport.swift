import Foundation

/// Whether a device draws Liquid Glass. tvOS 26 still runs on the Apple TV HD (AppleTV5,3) and the first
/// Apple TV 4K (AppleTV6,2), but Apple gives Liquid Glass only to the Apple TV 4K (2nd generation) and later.
public enum LiquidGlassSupport {
#if os(tvOS)
    /// The Apple TV's own model (AppleTV5,3 and AppleTV6,2 get no Liquid Glass).
    public static let current = drawsGlass(model: deviceModel)

    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
#else
    public static let current = true
#endif

    static func drawsGlass(model: String) -> Bool {
        guard model.hasPrefix("AppleTV"), let major = Int(model.dropFirst(7).prefix(while: \.isNumber)) else { return true }
        return major >= 11
    }
}
