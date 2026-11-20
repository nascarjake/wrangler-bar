import AppKit
import Darwin
import WranglerBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: CLIController
    let defaults: UserDefaults
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?
    let automatic: Bool
    init(controller: CLIController = CLIController(), defaults: UserDefaults = .standard, automatic: Bool = true) {
        self.controller = controller; self.defaults = defaults; self.automatic = automatic
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard statusItem == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: "Wrangler Bar")
        statusItem.button?.setAccessibilityLabel("Wrangler Bar")
        statusItem.button?.toolTip = "Wrangler Bar — profile status and sign-in"
        statusItem.menu = menu; menu.autoenablesItems = false
        controller.changed = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
        if automatic {
            checkTools()
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.controller.busy else { return }
                    await self.controller.loadProfiles(); await self.controller.refresh()
                }
            }
        }
    }
    @discardableResult
    func add(_ title: String, action: Selector? = nil, to targetMenu: NSMenu? = nil,
             enabled: Bool = true, profile: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = action != nil && enabled; item.representedObject = profile
        (targetMenu ?? menu).addItem(item); return item
    }
    func time(_ date: Date?) -> String { date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Not yet checked" }
    func rebuildMenu() {
        menu.removeAllItems()
        add("Wrangler Bar · 0.2.0")
        add(controller.status)
        if let tools = controller.installation { add("CLI source: " + tools.source.rawValue) }
        menu.addItem(.separator())
        for record in controller.profiles {
            let title = record.name + " — " + record.state.rawValue + (controller.activeProfile == record.name ? " · Working…" : "")
            let item = add(title)
            let submenu = NSMenu(); submenu.autoenablesItems = false; item.submenu = submenu; item.isEnabled = true
            add("Checked: " + time(record.checkedAt), to: submenu)
            add(record.note, to: submenu)
            add("Project bindings: \(record.bindingCount)", to: submenu)
            add("Last completed sign-in: " + time(record.lastSignInAt), to: submenu)
            let scopesItem = add("Last verified scopes: \(record.scopes.count)", to: submenu)
            let scopesMenu = NSMenu(); scopesMenu.autoenablesItems = false; scopesItem.submenu = scopesMenu; scopesItem.isEnabled = true
            add("Verified: " + time(record.scopesCheckedAt), to: scopesMenu)
            for scope in record.scopes { add(scope, to: scopesMenu) }
            submenu.addItem(.separator())
            add("Refresh \(record.name)", action: #selector(refreshProfile(_:)), to: submenu,
                enabled: !controller.busy && record.registered && controller.installation != nil, profile: record.name)
            add("Sign in to \(record.name)…", action: #selector(signIn(_:)), to: submenu,
                enabled: !controller.busy && record.registered && controller.installation != nil, profile: record.name)
        }
        if controller.profiles.isEmpty { add("No registered profiles loaded") }
        menu.addItem(.separator())
        add("Refresh all profiles", action: #selector(refreshAll), enabled: !controller.busy && controller.installation != nil, key: "r")
        add("Reload profile list", action: #selector(reloadProfiles), enabled: !controller.busy && controller.installation != nil)
        add("Cancel current operation", action: #selector(cancel), enabled: controller.busy)
        menu.addItem(.separator())
        add("Find installed tools", action: #selector(checkTools), enabled: !controller.busy)
        add("Choose Node.js executable…", action: #selector(chooseNode), enabled: !controller.busy)
        add("Choose Wrangler executable…", action: #selector(chooseWrangler), enabled: !controller.busy)
        add("Clear manual tool paths…", action: #selector(clearManualPaths), enabled: !controller.busy)
        add("Help & privacy", action: #selector(help), key: "?")
        add("Open project on GitHub", action: #selector(project))
        add("Quit Wrangler Bar", action: #selector(quit), key: "q")
    }
    @objc func checkTools() {
        Task {
            await controller.check(nodeOverride: defaults.string(forKey: "nodePath"), wranglerOverride: defaults.string(forKey: "wranglerPath"))
            await controller.loadProfiles(); await controller.refresh()
        }
    }
    @objc func refreshAll() { Task { await controller.refresh() } }
    @objc func reloadProfiles() { Task { await controller.loadProfiles(); await controller.refresh() } }
    @objc func refreshProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Task { await controller.refresh(name) }
    }
    @objc func signIn(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // The profile-specific action is the explicit initiation; normal Cloudflare browser approval still follows.
        Task { await controller.signIn(profile: name) }
    }
    @objc func cancel() { controller.cancel() }
    func choose(_ title: String, key: String) {
        let panel = NSOpenPanel(); panel.title = title
        panel.message = "Select an existing executable. Press ⌘⇧G to enter a path. Nothing is installed."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let path = panel.url?.path { defaults.set(path, forKey: key); checkTools() }
    }
    @objc func chooseNode() { choose("Choose a supported Node LTS executable", key: "nodePath") }
    @objc func chooseWrangler() { choose("Choose the installed Wrangler JavaScript entry", key: "wranglerPath") }
    @objc func clearManualPaths() {
        let alert = NSAlert(); alert.messageText = "Clear the app’s manual tool paths?"
        alert.informativeText = "Find installed tools normally honors your manual choices. Clearing them changes only this app’s executable selection and enables automatic discovery. It does not install tools or change Wrangler profiles."
        alert.addButton(withTitle: "Clear tool paths"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            defaults.removeObject(forKey: "nodePath"); defaults.removeObject(forKey: "wranglerPath"); checkTools()
        }
    }
    @objc func help() {
        let alert = NSAlert(); alert.messageText = "Wrangler Bar · Profiles"
        alert.informativeText = "Each profile has its own status, scopes and check time. Signed in means Wrangler verified that selected profile; Reauthentication needed means authentication was rejected; Unknown covers network, permission or CLI failures. Scopes are labeled with their last verification time.\n\nClick Sign in to NAME to start the installed official Wrangler’s auth create NAME browser flow. This may use a localhost callback. Approve the intended account in Cloudflare. Default, if listed, uses login --device. No other profile or project binding is changed. Cancel stops this app’s active CLI; approval already completed in the browser cannot be undone by cancellation.\n\nBackground checks run every 5 minutes with interactive login disabled. Wrangler owns credential storage and any ordinary session refresh. The app reads no token files, exports no tokens, logs no CLI output, and shows no emails or account IDs. It stores executable choices only. Profile details stay in memory.\n\nDiscovery prefers installed Node LTS and npm Wrangler entries. A validated npm-cache fallback is labeled temporary. Manual paths are honored; nothing is downloaded. Requirements: Node 22.13+ LTS and Wrangler 4.160+."
        alert.addButton(withTitle: "Done"); alert.addButton(withTitle: "Official Wrangler profile guide")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string: "https://developers.cloudflare.com/workers/wrangler/profiles/")!) }
    }
    @objc func project() { NSWorkspace.shared.open(URL(string: "https://github.com/nascarjake/wrangler-bar")!) }
    @objc func quit() { timer?.invalidate(); controller.cancel(); NSApp.terminate(nil) }
}

actor NativeSmokeRunner: CommandRunning {
    nonisolated func cancel() {}
    func run(_ command: Command) async -> CommandResult {
        let args = command.arguments.first?.hasSuffix("wrangler.js") == true ? Array(command.arguments.dropFirst()) : command.arguments
        if args == ["--version"] { return CommandResult(status: 0, output: command.arguments.count == 1 ? "v22.22.3" : "4.160.0") }
        if args == ["auth", "create", "--help"] { return CommandResult(status: 0, output: "--browser --callback-host") }
        if command.environment[ProfilePolicy.selector] == "invalid;selector" { return CommandResult(status: 1, output: "Invalid profile name") }
        if args == ["auth", "list"] { return CommandResult(status: 0, output: "│ Profile │ Bound Directories │\n│ alpha │ /example/a │\n│ beta │ /example/b │\n│ gamma │ - │") }
        if args == ["whoami", "--json"] {
            switch command.environment[ProfilePolicy.selector] {
            case "alpha": return CommandResult(status: 0, output: #"{"loggedIn":true,"tokenPermissions":["account:read"]}"#)
            case "beta": return CommandResult(status: 1, output: #"{"loggedIn":false}"#)
            default: return CommandResult(status: 1, output: "Network unreachable")
            }
        }
        return CommandResult(status: 99)
    }
}

@main @MainActor
enum WranglerBarApp {
    static func main() {
        if CommandLine.arguments.contains("--diagnose-tools") {
            let controller = CLIController()
            Task { @MainActor in
                await controller.check()
                let result: [String: Any]
                if let tools = controller.installation {
                    result = ["ready": true, "nodeVersion": tools.nodeVersion.description,
                              "wranglerVersion": tools.wranglerVersion.description, "source": tools.source.rawValue]
                } else { result = ["ready": false, "status": controller.status] }
                print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
                exit(controller.installation == nil ? 1 : 0)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--print-login-plan") {
            let args = CommandLine.arguments
            let i = args.firstIndex(of: "--profile")
            let name = i.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "default"
            let command = ProfilePolicy.signInArguments(name: name)
            let result: [String: Any] = ["profile": name, "arguments": command as Any? ?? NSNull()]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); return
        }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--smoke-test") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("WranglerBarSmoke-" + UUID().uuidString)
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let node = root.appendingPathComponent("node").path, cli = root.appendingPathComponent("wrangler.js").path
            for file in [node, cli] { FileManager.default.createFile(atPath: file, contents: file == node ? Data([0xcf, 0xfa, 0xed, 0xfe]) : Data(), attributes: [.posixPermissions: 0o700]) }
            let controller = CLIController(runner: NativeSmokeRunner(), environment: ["HOME": root.path], directory: root.path)
            let delegate = AppDelegate(controller: controller, automatic: false); app.delegate = delegate
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            Task { @MainActor in
                await controller.check(nodeOverride: node, wranglerOverride: cli)
                await controller.loadProfiles(); await controller.refresh()
                precondition(controller.profiles.map(\.state) == [.signedIn, .reauthenticationNeeded, .unknown])
                precondition(delegate.statusItem.button?.accessibilityLabel() == "Wrangler Bar")
                for name in ["alpha", "beta", "gamma"] {
                    let item = delegate.menu.items.first { $0.title.hasPrefix(name + " — ") }!
                    precondition(item.submenu!.items.contains { $0.title == "Sign in to \(name)…" && $0.isEnabled })
                }
                print("Native three-profile menu smoke passed with mixed statuses; no live CLI or browser was used.")
                try? FileManager.default.removeItem(at: root)
                NSApp.terminate(nil)
            }
            withExtendedLifetime(delegate) { app.run() }
        } else {
            let delegate = AppDelegate(); app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
