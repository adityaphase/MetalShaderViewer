import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controlWindow: ControlWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            let alert = NSAlert()
            alert.messageText = "No Metal device available"
            alert.informativeText = "This Mac does not expose a Metal-capable GPU."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        NSApp.mainMenu = Self.makeMenu()

        let controller = ControlWindowController(device: device)
        controlWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Allows `open -a MetalShaderViewer.app --args /path/to/shader.metal`
        // and `swift run MetalShaderViewer shader.metal`.
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            controller.load(url: URL(fileURLWithPath: path).standardizedFileURL)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        controlWindow?.load(url: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon brings the control panel back after it was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { controlWindow?.showWindow(nil) }
        return true
    }

    @objc private func openDocument(_ sender: Any?) {
        controlWindow?.chooseShader()
    }

    private static func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Metal Shader Viewer",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Metal Shader Viewer",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Metal Shader Viewer",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Shader…",
                         action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
