import OcteliumCore
import SwiftUI

@main
struct OcteliumApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .octeliumTheme()
                .environment(model)
                .preferredColorScheme(getColorScheme(model.prefs.theme))
                .onOpenURL { url in
                    model.handleAuthCallback(url)
                }
                .onAppear {
                    model.start()
                }
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                model.onActive()
            }
        }
    }
}
