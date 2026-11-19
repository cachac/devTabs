import AppKit
import ApplicationServices

enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/devTabs.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let wm = WindowManager()
    private var statusItem: NSStatusItem?
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowManager.shared = wm
        buildMenu()
        if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            begin()
            return
        }
        Log.write("esperando el permiso de Accesibilidad")
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.begin()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wm.stop()
    }

    private func begin() {
        Keys.register(wm)
        wm.start()
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "devTabs")
        let menu = NSMenu()
        menu.addItem(withTitle: "Prender o apagar el tiling en este monitor", action: #selector(toggleTiling), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reacomodar", action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir de devTabs", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleTiling() { wm.toggleTiling() }
    @objc private func reload() { wm.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
}
