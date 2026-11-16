import SwiftUI

@main
struct WakeUpApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Log.write("🚀 App 程序啟動")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.onActive() } else { model.onInactive() }
        }
    }
}
