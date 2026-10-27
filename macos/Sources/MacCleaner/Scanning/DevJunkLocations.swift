import Foundation

/// Well-known developer tool cache/build locations.
enum DevJunkLocations {
    struct Location {
        let name: String
        let path: URL
        let note: String
        /// Regenerated automatically with no loss beyond a slower next build/install.
        let isRecommended: Bool
    }

    static var all: [Location] {
        func p(_ relative: String) -> URL { DiskUtils.home.appendingPathComponent(relative) }

        return [
            Location(name: "Xcode DerivedData", path: p("Library/Developer/Xcode/DerivedData"), note: "Build products. Xcode rebuilds them.", isRecommended: true),
            Location(name: "iOS Device Support", path: p("Library/Developer/Xcode/iOS DeviceSupport"), note: "Debug symbols. Re-downloaded when a device is next connected.", isRecommended: true),
            Location(name: "watchOS Device Support", path: p("Library/Developer/Xcode/watchOS DeviceSupport"), note: "Debug symbols. Re-downloaded when a device is next connected.", isRecommended: true),
            Location(name: "Simulator caches", path: p("Library/Developer/CoreSimulator/Caches"), note: "Rebuilt by the simulator.", isRecommended: true),
            Location(name: "Xcode Archives", path: p("Library/Developer/Xcode/Archives"), note: "Old app builds. Needed to symbolicate crash reports for shipped versions.", isRecommended: false),
            Location(name: "npm cache", path: p(".npm/_cacache"), note: "Re-downloaded by npm as needed.", isRecommended: true),
            Location(name: "Yarn cache", path: p("Library/Caches/Yarn"), note: "Re-downloaded by Yarn as needed.", isRecommended: true),
            Location(name: "pnpm store", path: p("Library/pnpm/store"), note: "Re-downloaded by pnpm as needed.", isRecommended: true),
            Location(name: "pip cache", path: p("Library/Caches/pip"), note: "Re-downloaded by pip as needed.", isRecommended: true),
            Location(name: "Homebrew downloads", path: p("Library/Caches/Homebrew"), note: "Old installers. Same as `brew cleanup`.", isRecommended: true),
            Location(name: "CocoaPods cache", path: p("Library/Caches/CocoaPods"), note: "Re-downloaded by CocoaPods as needed.", isRecommended: true),
            Location(name: "Cargo registry cache", path: p(".cargo/registry/cache"), note: "Re-downloaded by Cargo as needed.", isRecommended: true),
            Location(name: "Cargo registry sources", path: p(".cargo/registry/src"), note: "Re-extracted by Cargo as needed.", isRecommended: true),
            Location(name: "Gradle caches", path: p(".gradle/caches"), note: "Re-downloaded by Gradle as needed.", isRecommended: true),
            Location(name: "Go module cache", path: p("go/pkg/mod"), note: "Re-downloaded by Go as needed. Files are read-only, so this may need a manual delete.", isRecommended: false),
            Location(name: "~/.cache", path: p(".cache"), note: "Shared cache folder for many command-line tools. Check what's in it first.", isRecommended: false),
        ]
    }

    /// Paths owned by this category. The caches scanner skips them so the same folder isn't listed twice.
    static var pathsInsideLibraryCaches: Set<String> {
        let caches = DiskUtils.library.appendingPathComponent("Caches").path
        return Set(all.map(\.path.path).filter { $0.hasPrefix(caches) })
    }
}
