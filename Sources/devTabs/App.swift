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
        menu.addItem(withTitle: "Prender o apagar el tiling en este workspace", action: #selector(toggleTiling), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reacomodar", action: #selector(reload), keyEquivalent: "").target = self
        let gaps = NSMenu()
        for value in [0, 2, 4, 8, 12, 16, 24] {
            let option = gaps.addItem(withTitle: "\(value) px", action: #selector(chooseGap(_:)), keyEquivalent: "")
            option.target = self
            option.tag = value
            option.state = CGFloat(value) == wm.config.gap ? .on : .off
        }
        menu.addItem(withTitle: "Separación entre ventanas", action: nil, keyEquivalent: "").submenu = gaps
        menu.addItem(withTitle: "Atajos", action: nil, keyEquivalent: "").submenu = shortcutsMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "Salir de devTabs", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    /// Lista de sólo lectura: elegir una fila no hace nada, sólo cierra el menú.
    private func shortcutsMenu() -> NSMenu {
        let list = NSMenu()
        list.autoenablesItems = false
        func header(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            item.isEnabled = false
            list.addItem(item)
        }
        func row(_ keys: String, _ action: String) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 170)]
            let text = "\(keys)\t\(action)"
            let item = NSMenuItem(title: text, action: #selector(readOnly), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph, .font: NSFont.menuFont(ofSize: 0)])
            list.addItem(item)
        }
        header("Control + Comando +")
        for entry in Keys.reference { row(entry.keys, entry.action) }
        list.addItem(.separator())
        header("Con el mouse")
        row("Clic en una pestaña", "Activarla")
        row("Arrastrar una pestaña", "Llevarla a otra posición")
        row("Arrastrar un borde", "Cambiar tamaños o la franja del acordeón")
        row("Soltar en otro monitor", "Acomodar la ventana ahí")
        return list
    }

    @objc private func readOnly() {}

    @objc private func chooseGap(_ sender: NSMenuItem) {
        wm.setGap(CGFloat(sender.tag))
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func toggleTiling() { wm.toggleTiling() }
    @objc private func reload() { wm.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
}
