import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloads.completion = completionHandler
    }
}

@main
struct WetOwlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .models(app)
                .preferredColorScheme(.dark)
                .tint(Theme.high)
        }
        .onChange(of: phase) { p in app.phaseChanged(p) }
    }
}
