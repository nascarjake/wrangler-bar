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
        add(profile.isEmpty ? "Profile: Wrangler default" : "Named profile selected · Terminal required")
        menu.addItem(.separator())
        add("Sign in to default Cloudflare profile…", #selector(signIn), key: "s", enabled: !controller.busy && controller.installation != nil && profile.isEmpty)
        add("Cancel current operation", #selector(cancel), enabled: controller.busy)
        add("Check installed tools", #selector(checkTools), key: "r", enabled: !controller.busy)
        menu.addItem(.separator())
        add("Choose Wrangler executable…", #selector(chooseWrangler), enabled: !controller.busy)
        add("Choose Node.js executable…", #selector(chooseNode), enabled: !controller.busy)
        add("Named-profile setup help…", #selector(namedProfileHelp))
        if !profile.isEmpty { add("Use default profile in this app…", #selector(useDefaultProfile), enabled: !controller.busy) }
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
        guard profile.isEmpty else { namedProfileHelp(); return }
        guard !controller.busy, controller.installation != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Sign in with Cloudflare?"
        alert.informativeText = "Wrangler will open your default browser. Approve only the Cloudflare account and permissions you intend to use. This updates Wrangler’s default profile. Named profiles use the separate Terminal flow shown in Named-profile setup help. The app never signs you out or selects a browser account."
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
    @objc func useDefaultProfile() {
        let alert = NSAlert()
        alert.messageText = "Use the default profile in Wrangler Bar?"
        alert.informativeText = "Version 0.1.0 saved a named-profile choice that Wrangler device login does not support. This clears only the app’s saved choice and enables its default-profile button. It does not run Wrangler, change credentials, or alter project bindings. A later sign-in will explicitly ask before updating Wrangler’s default profile."
        alert.addButton(withTitle: "Use default in this app"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            defaults.removeObject(forKey: "profile"); rebuildMenu()
        }
    }
    @objc func namedProfileHelp() {
        let alert = NSAlert()
        alert.messageText = "Named profiles use Wrangler’s Terminal flow"
        alert.informativeText = "Wrangler reserves login --device for its default profile and rejects login --profile NAME. This app does not start named-profile authentication or silently switch to the default.\n\nTo create or re-authenticate a named profile yourself in Terminal, use your installed Wrangler:\n\nwrangler auth create NAME\n\nReplace NAME with your intended profile. Approve the intended account in Cloudflare. This documented flow may use a localhost callback; check wrangler auth create --help for the flags supported by your version. Bind it to a project only if you intend to, using wrangler auth activate NAME /path/to/project. The app runs none of these commands."
        alert.addButton(withTitle: "Done"); alert.addButton(withTitle: "Cloudflare profile guide")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://developers.cloudflare.com/workers/wrangler/profiles/")!)
        }
    }
    @objc func help() {
        let alert = NSAlert()
        alert.messageText = "Wrangler Bar · Help"
        alert.informativeText = "1. Install a supported Node.js LTS and Wrangler yourself using Cloudflare’s guide. Node 22.13+ and Wrangler 4.119+ with --device are required.\n\n2. If Finder cannot find your tools, choose the Node and Wrangler executables from this menu. Project installs use node_modules/.bin/wrangler. No shell startup files are sourced.\n\n3. Choose Sign in to default Cloudflare profile. Cloudflare opens in your default browser and asks for approval. For named profiles, use Named-profile setup help and Wrangler’s Terminal flow. If no browser opens for default sign-in, cancel and run wrangler login --device in Terminal for Wrangler’s own instructions.\n\nReadiness is a tool check, not a check of your current Cloudflare account. Sign-in results describe this session only. No account details or device codes are displayed or saved by the app."
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
        // A side-effect-free test seam exposes the same command policy used by signIn.
        if CommandLine.arguments.contains("--print-login-plan") {
            let arguments = CommandLine.arguments
            let index = arguments.firstIndex(of: "--profile")
            let profile = index.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? ""
            let command = LoginPolicy.deviceArguments(profile: profile)
            let result: [String: Any] = ["mode": profile.isEmpty ? "default-device" : "named-profile-help",
                                         "arguments": command as Any? ?? NSNull()]
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            if CommandLine.arguments.contains("--smoke-test") {
                // Build the real native menu without invoking a CLI or browser.
                delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                precondition(delegate.statusItem.menu === delegate.menu)
                precondition(delegate.menu.items.contains { $0.title == "Sign in to default Cloudflare profile…" && !$0.isEnabled })
                precondition(delegate.statusItem.button?.accessibilityLabel() == "Wrangler Bar")
                let suite = "WranglerBarSmoke-" + UUID().uuidString
                let preferences = UserDefaults(suiteName: suite)!
                preferences.setVolatileDomain(["profile": "legacy-named-profile"], forName: UserDefaults.argumentDomain)
                let legacy = AppDelegate(defaults: preferences)
                legacy.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                precondition(!legacy.profile.isEmpty)
                precondition(legacy.menu.items.contains { $0.title == "Sign in to default Cloudflare profile…" && !$0.isEnabled })
                precondition(legacy.menu.items.contains { $0.title == "Named-profile setup help…" && $0.isEnabled })
                precondition(legacy.menu.items.contains { $0.title == "Use default profile in this app…" })
                print("Native default and legacy named-profile menu smoke passed; authentication was not started.")
            } else { app.run() }
        }
    }
}
