import SwiftUI
import CoreText

@main struct MyApp: App {
    init() {
        // Bundled masthead font (Chomsky, OFL).
        if let url = Bundle.main.url(forResource: "Chomsky", withExtension: "otf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
