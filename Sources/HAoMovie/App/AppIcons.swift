import SwiftUI

// MARK: App icon
// HAo Movie ships one icon: the clapperboard. Yingxia shipped twenty-one alternates with a picker;
// those were its icons, not HAo Movie's, and the picker showed twenty-one blank tiles here because
// neither their artwork nor their alternate icon sets came over. So there is no picker and no
// alternate-icon machinery. The one artwork lives in the asset catalog as AppIconArt-MediaPocketPurple,
// and AppMark draws it on the app's own pages.

/// The app's icon artwork, for the pages that draw it (AppMark).
@MainActor @Observable final class AppIcons {
    static let shared = AppIcons()

    /// The icon's artwork as the app draws it on its own pages (AppMark).
    var artwork: Image { Image("AppIconArt-MediaPocketPurple") }
}
