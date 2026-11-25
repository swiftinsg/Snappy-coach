import SwiftUI

@main struct MyApp: App {
    init() {
        // Light and Exposure became one mode, and so did Angle & Perspective and Focus; someone
        // last in an old mode carries on in the one it joined.
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "adviceTopic"), AdviceTopic(rawValue: saved) == nil,
           let merged = AdviceTopic.stored(saved) {
            defaults.set(merged.rawValue, forKey: "adviceTopic")
        }
    }

    var body: some Scene {
        WindowGroup {
            AutoRenderingView()
                .appleIntelligenceAlert()
        }
    }
}
