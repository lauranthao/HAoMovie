// swift-tools-version: 6.0
import PackageDescription

// Local package for the QuickJS-NG runtime (mirrors Yingxia's TVCore
// QuickJS target: same sources, same public headers, same defines).
// The Xcode project does NOT compile the .c files itself — hand-generated
// projects hit Xcode's "no rule to process file ... of type sourcecode.c"
// for them (primary #28/#29). The C target here is the only compilation
// route. Sources live in Sources/HAoMovie/Vendor/QuickJS, reached through
// the Vendor symlink in this directory (same layout as Yingxia's
// Packages/TVCore/Vendor symlink).
let package = Package(
    name: "QuickJS",
    platforms: [.iOS(.v17)],
    products: [.library(name: "QuickJS", targets: ["QuickJS"])],
    targets: [.target(
        name: "QuickJS",
        path: "Vendor/QuickJS",
        exclude: ["LICENSE", "UPSTREAM.md"],
        sources: ["quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c", "TVScript.c"],
        publicHeadersPath: "include",
        cSettings: [.define("_GNU_SOURCE"), .define("QUICKJS_NG_BUILD"), .define("NDEBUG")]
    )]
)
