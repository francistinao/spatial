import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment.makeDefault()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(environment: environment)
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.virtualAudioRoutingService.deactivate()
    }
}
