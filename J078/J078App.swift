import SwiftUI

@main
struct J078App: App {
    @StateObject private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            TabView {
                ScooterView(ble: ble)
                    .tabItem { Label("Scooter", systemImage: "scooter") }
                LogView(ble: ble)
                    .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
            }
        }
    }
}
