import SwiftUI
import CoreText

enum TabTypography {
    private static let registerSuite: Void = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        if let url = bundle.url(forResource: "SUITE-Bold", withExtension: "otf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func suite(size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        _ = registerSuite
        return .custom("SUITE-Bold", size: size, relativeTo: style)
    }

    static let favoriteLabel = suite(size: NSFont.systemFontSize, relativeTo: .body)
}
