import AppKit
import WranglerBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller: CLIController
    let defaults: UserDefaults
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var nodePath: String? { defaults.string(forKey: "nodePath") }
    var wranglerPath: String? { defaults.string(forKey: "wranglerPath") }
    var profile: String { defaults.string(forKey: "profile") ?? "" }

    init(controller: CLIController = CLIController(), defaults: UserDefaults = .standard) {
        self.controller = controller; self.defaults = defaults
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: "Wrangler Bar")
        statusItem.button?.setAccessibilityLabel("Wrangler Bar")
        statusItem.button?.toolTip = "Wrangler Bar — Cloudflare CLI sign-in"
        // Native NSStatusItem menus support primary click, secondary click and keyboard/VoiceOver navigation.
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        controller.changed = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") { checkTools() }
    }
    func add(_ title: String, _ action: Selector? = nil, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = action != nil && enabled
        menu.addItem(item)
    }
    func rebuildMenu() {
        menu.removeAllItems()
        add("Wrangler Bar")
        add(controller.status)
        add(profile.isEmpty ? "Profile: Wrangler default" : "Profile: \(profile)")
        menu.addItem(.separator())
        add("Sign in to Cloudflare…", #selector(signIn), key: "s", enabled: !controller.busy && controller.installation != nil)
        add("Cancel current operation", #selector(cancel), enabled: controller.busy)
        add("Check installed tools", #selector(checkTools), key: "r", enabled: !controller.busy)
        menu.addItem(.separator())
        add("Choose Wrangler executable…", #selector(chooseWrangler), enabled: !controller.busy)
        add("Choose Node.js executable…", #selector(chooseNode), enabled: !controller.busy)
        add("Choose authentication profile…", #selector(chooseProfile), enabled: !controller.busy)
        add("Use automatic tool discovery", #selector(resetTools), enabled: !controller.busy)
        menu.addItem(.separator())
        add("Help & troubleshooting", #selector(help), key: "?")
        add("Open project on GitHub", #selector(project))
        add("Quit Wrangler Bar", #selector(quit), key: "q")
    }
    @objc func checkTools() {
        Task { await controller.check(nodeOverride: nodePath, wranglerOverride: wranglerPath) }
    }
    @objc func signIn() {
        guard !controller.busy, controller.installation != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Sign in with Cloudflare?"
        alert.informativeText = "Wrangler will open your default browser. Approve only the Cloudflare account and permissions you intend to use. This updates Wrangler’s \(profile.isEmpty ? "default" : profile) profile. The app never signs you out or selects a browser account."
        alert.addButton(withTitle: "Continue to Cloudflare")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedProfile = profile
        Task { await controller.signIn(profile: selectedProfile) }
    }
    @objc func cancel() { controller.cancel() }
    func choose(_ title: String, key: String) {
        let panel = NSOpenPanel()
        panel.title = title; panel.message = "Select an existing executable. Nothing will be installed. Press ⌘⇧G to enter a path."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            defaults.set(url.path, forKey: key); checkTools()
        }
    }
    @objc func chooseWrangler() { choose("Choose the installed Wrangler executable", key: "wranglerPath") }
    @objc func chooseNode() { choose("Choose the installed Node.js executable", key: "nodePath") }
    @objc func resetTools() { defaults.removeObject(forKey: "nodePath"); defaults.removeObject(forKey: "wranglerPath"); checkTools() }
    @objc func chooseProfile() {
        let alert = NSAlert()
        alert.messageText = "Wrangler authentication profile"
        alert.informativeText = "Leave blank for Wrangler’s default profile. A named profile is passed explicitly to login; the app does not change project bindings. Use letters, digits, dots, underscores or hyphens."
        let field = NSTextField(string: profile); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil {
                defaults.set(name, forKey: "profile"); rebuildMenu()
            } else { help() }
        }
    }
    @objc func help() {
        let alert = NSAlert()
        alert.messageText = "Wrangler Bar · Help"
        alert.informativeText = "1. Install a supported Node.js LTS and Wrangler yourself using Cloudflare’s guide. Node 22.13+ and Wrangler 4.119+ with --device are required.\n\n2. If Finder cannot find your tools, choose the Node and Wrangler executables from this menu. Project installs use node_modules/.bin/wrangler. No shell startup files are sourced.\n\n3. Choose the intended profile, then Sign in. Cloudflare opens in your default browser and asks for approval. If no browser opens, cancel and run wrangler login --device in Terminal for Wrangler’s own instructions.\n\nReadiness is a tool check, not a check of your current Cloudflare account. Sign-in results describe this session only. No account details or device codes are displayed or saved by the app."
        alert.addButton(withTitle: "Done"); alert.addButton(withTitle: "Cloudflare setup guide")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://developers.cloudflare.com/workers/wrangler/install-and-update/")!)
        }
    }
    @objc func project() { NSWorkspace.shared.open(URL(string: "https://github.com/nascarjake/wrangler-bar")!) }
    @objc func quit() { controller.cancel(); NSApp.terminate(nil) }
}

@main
@MainActor
enum WranglerBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            if CommandLine.arguments.contains("--smoke-test") {
                // Build the real native menu without invoking a CLI or browser.
                delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                precondition(delegate.statusItem.menu === delegate.menu)
                precondition(delegate.menu.items.contains { $0.title == "Sign in to Cloudflare…" && !$0.isEnabled })
                precondition(delegate.statusItem.button?.accessibilityLabel() == "Wrangler Bar")
                print("Native menu smoke passed; authentication was not started.")
            } else { app.run() }
        }
    }
}
