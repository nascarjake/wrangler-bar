import Foundation

@MainActor
public final class CLIController {
    public private(set) var busy = false
    public private(set) var installation: Installation?
    public private(set) var status = "Find tools to load your Wrangler profiles"
    public private(set) var profiles: [ProfileRecord] = []
    public private(set) var activeProfile: String?
    public var changed: (() -> Void)?
    private let runner: any CommandRunning
    private let environment: [String: String]
    private let directory: String
    private let now: () -> Date
    private var cancelRequested = false
    public init(runner: any CommandRunning = ProcessRunner(), environment: [String: String] = ProcessInfo.processInfo.environment,
                directory: String? = nil, now: @escaping () -> Date = Date.init) {
        self.runner = runner; self.environment = environment; self.now = now
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("WranglerBar-" + UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createSymbolicLink(atPath: self.directory + "/discard.log", withDestinationPath: "/dev/null")
    }
    private var logsSafe: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: directory + "/discard.log")) == "/dev/null" }
    private func command(_ path: String, _ args: [String], node: String, capture: Bool = true,
                         profile: String? = nil, login: Bool = false, isolatedProbe: Bool = false) -> Command {
        var env = Discovery.safeEnvironment(base: environment, node: node)
        env["WRANGLER_LOG_PATH"] = directory + "/discard.log"
        if !login { env["CI"] = "true" }
        if let profile { env[ProfilePolicy.selector] = profile }
        if isolatedProbe {
            env["HOME"] = directory + "/probe-home"
            env["XDG_CONFIG_HOME"] = directory + "/probe-home/config"
            env["WRANGLER_HOME"] = directory + "/probe-home/wrangler"
        }
        var result = Command(executable: node, arguments: path == node ? args : [path] + args,
                             environment: env, directory: directory, capture: capture, timeout: login ? 330 : 20)
        result.captureErrors = capture
        return result
    }
    public func check(nodeOverride: String? = nil, wranglerOverride: String? = nil) async {
        guard !busy else { return }
        busy = true; cancelRequested = false; status = "Checking installed tools…"; changed?()
        defer { busy = false; changed?() }
        guard logsSafe else { status = "Cannot safely discard CLI logs · Restart the app"; return }
        installation = nil
        let home = environment["HOME"] ?? NSHomeDirectory()
        let nodes = nodeOverride.map { [$0] } ?? Discovery.directories(home: home, environment: environment).map { $0 + "/node" }
        let clis = Discovery.wranglers(home: home, environment: environment, manual: wranglerOverride)
        var validatedNodes: [(String, Version)] = []
        for node in nodes where FileManager.default.isExecutableFile(atPath: node) {
            if !Discovery.isNativeExecutable(node) { continue }
            if nodeOverride == nil && !Discovery.trustedNode(node, home: home) { continue }
            if cancelRequested { status = "Tool check cancelled"; return }
            let version = await runner.run(command(node, ["--version"], node: node, isolatedProbe: true))
            guard version.status == 0, let nodeVersion = Version(version.output), nodeVersion.supportsNode else { continue }
            validatedNodes.append((node, nodeVersion))
        }
        // Prefer an installed Wrangler with any supported runtime over a cache entry.
        for cli in clis where FileManager.default.isExecutableFile(atPath: cli.path) {
            for (node, nodeVersion) in validatedNodes {
                if cancelRequested { status = "Tool check cancelled"; return }
                let version = await runner.run(command(cli.path, ["--version"], node: node, isolatedProbe: true))
                guard version.status == 0, let cliVersion = Version(version.output), cliVersion.supportsWrangler else { continue }
                let help = await runner.run(command(cli.path, ["auth", "create", "--help"], node: node, isolatedProbe: true))
                guard help.status == 0, help.output.contains("--browser"), help.output.contains("--callback-host") else { continue }
                // Verify the explicit, per-process selector in an EMPTY home before any real profile is queried.
                let selector = await runner.run(command(cli.path, ["whoami", "--json"], node: node,
                                                       profile: "invalid;selector", isolatedProbe: true))
                guard selector.status != 0, selector.output.contains("Invalid profile name") else { continue }
                guard !cancelRequested else { status = "Tool check cancelled"; return }
                installation = Installation(node: node, wrangler: cli.path, nodeVersion: nodeVersion, wranglerVersion: cliVersion, source: cli.source)
                status = "Ready · Node \(nodeVersion) · Wrangler \(cliVersion) · \(cli.source.rawValue)"
                return
            }
        }
        status = !validatedNodes.isEmpty ? "Choose Wrangler 4.160+ with named-profile support" : "Choose a supported Node LTS · 22.13+"
        if nodeOverride != nil || wranglerOverride != nil { status += " · Manual paths retained" }
        for i in profiles.indices { profiles[i].state = .unknown; profiles[i].note = "Tools need attention" }
    }
    private func readCatalogue() async -> [ProfileRecord]? {
        guard let installation, logsSafe else { return nil }
        let result = await runner.run(command(installation.wrangler, ["auth", "list"], node: installation.node))
        guard result.status == 0, !result.cancelled, !result.timedOut else { return nil }
        return ProfilePolicy.catalogue(result.output)
    }
    private func mergeCatalogue(_ catalogue: [ProfileRecord]) {
        let old = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
        profiles = catalogue.map { entry in
            var record = old[entry.name] ?? entry
            record.bindingCount = entry.bindingCount; record.registered = true
            return record
        } + profiles.filter { oldEntry in !catalogue.contains(where: { $0.name == oldEntry.name }) }.map {
            var missing = $0; missing.registered = false; missing.state = .unknown
            missing.note = "No longer listed by Wrangler; sign-in disabled"; return missing
        }
    }
    public func loadProfiles() async {
        guard !busy, installation != nil else { return }
        busy = true; cancelRequested = false; changed?()
        defer { busy = false; changed?() }
        guard let catalogue = await readCatalogue(), !cancelRequested else {
            status = "Could not read Wrangler’s profile list"
            for i in profiles.indices { profiles[i].state = .unknown; profiles[i].note = "Profile list unavailable" }
            return
        }
        mergeCatalogue(catalogue)
        status = catalogue.isEmpty ? "Wrangler lists no registered profiles" : "\(catalogue.count) registered profiles · Status checks every 5 minutes"
    }
    private func refreshOne(_ name: String) async {
        guard let installation, let index = profiles.firstIndex(where: { $0.name == name && $0.registered }), logsSafe,
              ProfilePolicy.valid(name), !cancelRequested else { return }
        activeProfile = name; changed?()
        let result = await runner.run(command(installation.wrangler, ["whoami", "--json"], node: installation.node, profile: name))
        let (state, scopes, note) = ProfilePolicy.identity(result)
        profiles[index].state = state; profiles[index].note = note; profiles[index].checkedAt = now()
        if state == .signedIn { profiles[index].scopes = scopes; profiles[index].scopesCheckedAt = profiles[index].checkedAt }
        activeProfile = nil; changed?()
    }
    public func refresh(_ name: String? = nil) async {
        guard !busy, installation != nil, logsSafe else { return }
        busy = true; cancelRequested = false; changed?()
        defer { busy = false; activeProfile = nil; changed?() }
        let names = name.map { [$0] } ?? profiles.filter(\.registered).map(\.name)
        for name in names {
            if cancelRequested { break }
            await refreshOne(name)
        }
    }
    public func signIn(profile name: String) async {
        guard !busy, let installation, logsSafe, let args = ProfilePolicy.signInArguments(name: name),
              profiles.contains(where: { $0.name == name && $0.registered }) else { return }
        busy = true; cancelRequested = false; activeProfile = name; changed?()
        defer { busy = false; activeProfile = nil; changed?() }
        // Recheck registration so a stale menu cannot create an unintended new profile.
        guard let catalogue = await readCatalogue(), catalogue.contains(where: { $0.name == name }), !cancelRequested else {
            if let i = profiles.firstIndex(where: { $0.name == name }) {
                profiles[i].state = .unknown; profiles[i].note = "Registration could not be confirmed; no login started"
            }
            return
        }
        if let i = profiles.firstIndex(where: { $0.name == name }) { profiles[i].note = "Waiting for browser approval for this profile…" }
        changed?()
        let result = await runner.run(command(installation.wrangler, args, node: installation.node, capture: false, profile: name, login: true))
        guard let i = profiles.firstIndex(where: { $0.name == name }) else { return }
        if cancelRequested || result.cancelled {
            profiles[i].state = .unknown; profiles[i].note = "Sign-in cancelled; refresh to check current status"
        } else if result.status == 0 && !result.timedOut {
            profiles[i].lastSignInAt = now()
            await refreshOne(name)
        } else {
            profiles[i].state = .unknown
            profiles[i].note = result.timedOut ? "Browser approval timed out; try again" : "Wrangler sign-in failed; no other profile was used"
        }
    }
    public func cancel() { cancelRequested = true; runner.cancel() }
}
