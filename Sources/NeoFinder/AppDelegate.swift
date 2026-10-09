import AppKit
import NeoFinderCore

@main
struct NeoFinderApplication {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: WorkspaceWindowController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = WorkspaceWindowController()
        mainWindow = controller
        controller.installMenus()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.servicesProvider = self
        NSApp.activate(ignoringOtherApps: true)
        for url in pendingURLs { controller.openExternal(url) }
        pendingURLs.removeAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if let mainWindow { mainWindow.openExternal(url) }
            else { pendingURLs.append(url) }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = mainWindow else { return .terminateNow }
        if controller.operationRunning {
            controller.explainRunningOperation()
            return .terminateCancel
        }
        controller.saveNow()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { mainWindow?.prepareForTermination() }

    @objc func openInNeoFinder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            error.pointee = "フォルダを選択してください。"
            return
        }
        for url in urls { mainWindow?.openExternal(url) }
    }
}
