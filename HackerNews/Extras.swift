import SwiftUI

// Hooks for build-specific additions. Source builds use these defaults, which do nothing;
// a build that defines THN_EXTRAS supplies its own versions.
#if !THN_EXTRAS
enum Extras {
    /// Runs once at launch.
    static func start() async {}
    /// Runs whenever the app returns to the foreground.
    static func didBecomeActive() {}
    /// Runs when the app goes to the background.
    static func didEnterBackground() {}
    /// Notes a screen or action by name, e.g. `note("story")`.
    static func note(_ name: String, _ details: [String: String] = [:]) {}
    /// The edition named under the masthead.
    static var edition: String { "Late Edition" }
}

extension View {
    /// Presentations attached at the root of the app.
    func extrasPresentations() -> some View { self }
}

/// An extra section at the foot of the account screens.
struct ExtrasAccountSection: View {
    var body: some View { EmptyView() }
}
#endif
