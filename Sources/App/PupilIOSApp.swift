import SwiftUI

@main
struct PupilIOSApp: App {
    // `Settings` / `Library` are the app's single stores; the views read them
    // through the environment, and the reader and the design system reach the
    // same instances through `shared`.
    @StateObject private var settings = Settings.shared
    @StateObject private var library = Library.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .preferredColorScheme(settings.colorScheme)
                .tint(AstryxTheme.shared.accent)
        }
    }
}
