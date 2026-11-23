import SwiftUI

@main struct MyApp: App {
    init() {
        // Light and Exposure became one mode; someone last in Exposure carries on in it.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "adviceTopic") == "exposure" {
            defaults.set(AdviceTopic.light.rawValue, forKey: "adviceTopic")
        }
    }

    var body: some Scene {
        WindowGroup {
            AutoRenderingView()
                .appleIntelligenceAlert()
        }
    }
}
