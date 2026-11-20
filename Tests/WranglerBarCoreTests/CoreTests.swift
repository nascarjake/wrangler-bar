import Foundation
import Testing
@testable import WranglerBarCore

actor FakeRunner: CommandRunning {
    var commands: [Command] = []
    var nodeVersion = "v22.22.3"
    var cliVersion = "4.160.0"
    var selectorSupported = true
    var failingVersionPairs = Set<String>()
    var names = ["alpha", "beta", "gamma"]
    var catalogueFails = false
    var identities: [String: CommandResult] = [
        "alpha": CommandResult(status: 0, output: #"{"loggedIn":true,"tokenPermissions":["account:read"],"email":"fixture@example.test","accounts":[{"id":"fixture-private-id"}]}"#),
        "beta": CommandResult(status: 1, output: #"{"loggedIn":false}"#),
        "gamma": CommandResult(status: 1, output: "Network unreachable")
    ]
    var loginResult = CommandResult(status: 0)
    var hold = false
    var waiting: CheckedContinuation<CommandResult, Never>?
    var cancellations = 0
    nonisolated func cancel() { Task { await stop() } }
    func stop() { cancellations += 1; waiting?.resume(returning: CommandResult(status: -1, cancelled: true)); waiting = nil }
    func configure(node: String = "v22.22.3", cli: String = "4.160.0", selector: Bool = true,
                   hold: Bool = false, result: CommandResult = CommandResult(status: 0)) {
        nodeVersion = node; cliVersion = cli; selectorSupported = selector; self.hold = hold; loginResult = result
    }
    func setNames(_ names: [String]) { self.names = names }
    func failVersionPair(node: String, cli: String) { failingVersionPairs.insert(node + "|" + cli) }
    func failCatalogue() { catalogueFails = true }
    func setIdentity(_ name: String, _ result: CommandResult) { identities[name] = result }
    func release() { waiting?.resume(returning: loginResult); waiting = nil }
    func run(_ command: Command) async -> CommandResult {
        commands.append(command)
        let args = command.arguments.first?.hasSuffix("wrangler.js") == true ? Array(command.arguments.dropFirst()) : command.arguments
        if args == ["--version"] {
            if let cli = command.arguments.first, failingVersionPairs.contains(command.executable + "|" + cli) { return CommandResult(status: 1) }
            return CommandResult(status: 0, output: command.arguments.count == 1 ? nodeVersion : cliVersion)
        }
        if args == ["auth", "create", "--help"] { return CommandResult(status: 0, output: "--browser --callback-host") }
        if command.environment[ProfilePolicy.selector] == "invalid;selector" {
            return selectorSupported ? CommandResult(status: 1, output: "Invalid profile name") : CommandResult(status: 1, output: #"{"loggedIn":false}"#)
        }
        if args == ["auth", "list"] {
            return catalogueFails ? CommandResult(status: 1) : CommandResult(status: 0, output: "│ Profile │ Bound Directories │\n" + names.map { "│ \($0) │ /example/\($0) │" }.joined(separator: "\n"))
        }
        if args == ["whoami", "--json"] { return identities[command.environment[ProfilePolicy.selector] ?? ""] ?? CommandResult(status: 1, output: #"{"loggedIn":false}"#) }
        if hold { return await withCheckedContinuation { waiting = $0 } }
        return loginResult
    }
}

@MainActor final class TestClock { var value = Date(timeIntervalSince1970: 1000) }

@Suite(.serialized) @MainActor
struct CoreTests {
    func fixture() throws -> (String, String, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for name in ["node", "wrangler.js"] {
            FileManager.default.createFile(atPath: root + "/" + name, contents: name == "node" ? Data([0xcf, 0xfa, 0xed, 0xfe]) : Data(), attributes: [.posixPermissions: 0o700])
        }
        return (root, root + "/node", root + "/wrangler.js")
    }
    func ready(_ fake: FakeRunner, root: String, node: String, cli: String, clock: TestClock = TestClock()) async -> CLIController {
        let controller = CLIController(runner: fake, environment: ["HOME": root], directory: root, now: { clock.value })
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        await controller.loadProfiles()
        return controller
    }
    @Test func exactNamedAndDefaultArgumentsRejectMetacharacters() {
        for name in ["alpha", "beta", "gamma", "Team_2"] {
            #expect(ProfilePolicy.signInArguments(name: name) == ["auth", "create", name, "--browser=true"])
        }
        #expect(ProfilePolicy.signInArguments(name: "default") == ["login", "--device", "--browser=true"])
        for name in ["", "--help", "a;touch /tmp/no", "$(id)", "a b", "a\nb", "../profile", "staging", "Default"] {
            #expect(ProfilePolicy.signInArguments(name: name) == nil)
        }
    }
    @Test func versionFloorsAndEnvironmentIsolation() {
        #expect(Version("v20.18.0")?.supportsNode == false)
        #expect(Version("v23.11.0")?.supportsNode == false)
        #expect(Version("v22.22.3")?.supportsNode == true)
        #expect(Version("4.159.0")?.supportsWrangler == false)
        #expect(Version("4.160.0")?.supportsWrangler == true)
        let env = Discovery.safeEnvironment(base: ["HOME": "/example", "CLOUDFLARE_API_TOKEN": "fixture", "CLOUDFLARE_AUTH_PROFILE": "wrong", "NODE_OPTIONS": "injected", "WRANGLER_AUTH_URL": "wrong", "BROWSER": "wrong", "PATH": "/arbitrary"], node: "/known/node")
        for key in ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_AUTH_PROFILE", "NODE_OPTIONS", "WRANGLER_AUTH_URL", "BROWSER"] { #expect(env[key] == nil) }
        #expect(env["PATH"]?.hasPrefix("/known:") == true)
        #expect(env["PATH"]?.contains("arbitrary") == false)
    }
    @Test func threeMixedStatesSeparateScopesAndTimestamps() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let clock = TestClock(), fake = FakeRunner()
        let controller = await ready(fake, root: root, node: node, cli: cli, clock: clock)
        #expect(controller.installation != nil)
        await controller.refresh()
        #expect(controller.profiles.map(\.state) == [.signedIn, .reauthenticationNeeded, .unknown])
        #expect(controller.profiles[0].scopes == ["account:read"])
        #expect(controller.profiles[1].scopes.isEmpty)
        #expect(controller.profiles.allSatisfy { $0.checkedAt == clock.value })
        #expect(!String(describing: controller.profiles).contains("fixture-private-id"))
        let alpha = controller.profiles[0], beta = controller.profiles[1]
        clock.value = Date(timeIntervalSince1970: 2000)
        await fake.setIdentity("gamma", CommandResult(status: 0, output: #"{"loggedIn":true,"tokenPermissions":["workers:write"]}"#))
        await controller.refresh("gamma")
        #expect(controller.profiles[0] == alpha && controller.profiles[1] == beta)
        #expect(controller.profiles[2].scopes == ["workers:write"])
        #expect(controller.profiles[2].checkedAt == clock.value)
        let calls = await fake.commands.filter { $0.arguments.suffix(2) == ["whoami", "--json"] && $0.environment[ProfilePolicy.selector] != "invalid;selector" }
        #expect(calls.map { $0.environment[ProfilePolicy.selector]! } == ["alpha", "beta", "gamma", "gamma"])
        #expect(calls.allSatisfy { $0.environment["CI"] == "true" })
    }
    @Test(arguments: ["alpha", "beta", "gamma"])
    func selectedProfileBrowserLoginRefreshesOnlyIt(name: String) async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let clock = TestClock(), fake = FakeRunner()
        let controller = await ready(fake, root: root, node: node, cli: cli, clock: clock)
        await controller.refresh()
        let others = controller.profiles.filter { $0.name != name }
        await fake.setIdentity(name, CommandResult(status: 0, output: #"{"loggedIn":true,"tokenPermissions":["d1:write"]}"#))
        clock.value = Date(timeIntervalSince1970: 3000)
        await controller.signIn(profile: name)
        #expect(controller.profiles.filter { $0.name != name } == others)
        let record = controller.profiles.first { $0.name == name }!
        #expect(record.state == .signedIn && record.lastSignInAt == clock.value && record.checkedAt == clock.value)
        let calls = await fake.commands
        let login = calls.first { !$0.capture }!
        #expect(login.arguments == [cli, "auth", "create", name, "--browser=true"])
        #expect(login.environment[ProfilePolicy.selector] == name)
        #expect(login.environment["CI"] == nil)
        #expect(login.environment["WRANGLER_LOG_PATH"] == root + "/discard.log")
        #expect(calls.last?.arguments == [cli, "whoami", "--json"])
        #expect(calls.last?.environment[ProfilePolicy.selector] == name)
    }
    @Test func duplicateLoginCancellationAndNoFallback() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner(); await fake.configure(hold: true)
        let controller = await ready(fake, root: root, node: node, cli: cli)
        await controller.refresh()
        let others = controller.profiles.filter { $0.name != "beta" }
        let task = Task { await controller.signIn(profile: "beta") }
        while await fake.waiting == nil { await Task.yield() }
        await controller.signIn(profile: "gamma")
        #expect(await fake.commands.filter { !$0.capture }.count == 1)
        controller.cancel(); await task.value
        #expect(!controller.busy && controller.activeProfile == nil)
        #expect(controller.profiles.filter { $0.name != "beta" } == others)
        #expect(controller.profiles[1].note.contains("cancelled"))
        #expect(controller.profiles[1].lastSignInAt == nil)
    }
    @Test func loginFailureDoesNotExposeOutputOrRefreshOtherProfiles() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner(); await fake.configure(result: CommandResult(status: 1, output: "SENSITIVE_FIXTURE_URL_CODE"))
        let controller = await ready(fake, root: root, node: node, cli: cli)
        await controller.signIn(profile: "alpha")
        #expect(controller.profiles[0].state == .unknown)
        #expect(!controller.profiles[0].note.contains("SENSITIVE"))
        #expect(controller.profiles[0].lastSignInAt == nil)
        #expect(controller.profiles[1].checkedAt == nil && controller.profiles[2].checkedAt == nil)
    }
    @Test func removedAndUnregisteredProfilesNeverStartOAuth() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner()
        let checked = await ready(fake, root: root, node: node, cli: cli)
        await fake.setNames(["alpha", "gamma"])
        await checked.signIn(profile: "beta")
        await checked.signIn(profile: "missing")
        #expect(await fake.commands.allSatisfy(\.capture))
        await checked.loadProfiles()
        #expect(checked.profiles.first { $0.name == "beta" }?.registered == false)
    }
    @Test func unknownDoesNotBecomeSignedOutAndKeepsLastScope() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner(), clock = TestClock()
        let controller = await ready(fake, root: root, node: node, cli: cli, clock: clock)
        await controller.refresh("alpha")
        let oldScopeTime = controller.profiles[0].scopesCheckedAt
        clock.value = Date(timeIntervalSince1970: 4000)
        await fake.setIdentity("alpha", CommandResult(status: 1, output: "permission denied or network unavailable"))
        await controller.refresh("alpha")
        #expect(controller.profiles[0].state == .unknown)
        #expect(controller.profiles[0].scopes == ["account:read"])
        #expect(controller.profiles[0].scopesCheckedAt == oldScopeTime)
        #expect(controller.profiles[0].checkedAt == clock.value)
        await fake.failCatalogue(); await controller.signIn(profile: "alpha")
        #expect(await fake.commands.allSatisfy(\.capture))
    }
    @Test func selectorAndOldToolsFailClosedWithoutRealProfileChecks() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner(); await fake.configure(selector: false)
        let controller = await ready(fake, root: root, node: node, cli: cli)
        #expect(controller.installation == nil)
        #expect(controller.profiles.isEmpty)
        await fake.configure(cli: "4.159.0")
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        #expect(controller.installation == nil)
        await fake.configure(node: "v23.11.0")
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        #expect(controller.installation == nil)
    }
    @Test func defaultIsSeparateAndUsesOnlyDeviceFlow() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner(); await fake.setNames(["default", "alpha"])
        let controller = await ready(fake, root: root, node: node, cli: cli)
        await controller.signIn(profile: "default")
        let login = await fake.commands.first { !$0.capture }!
        #expect(login.arguments == [cli, "login", "--device", "--browser=true"])
        #expect(login.environment[ProfilePolicy.selector] == "default")
    }
    @Test func stableDiscoveryPrecedesLabelledCacheAndHonorsManualPaths() throws {
        let (root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let bin = root + "/.nvm/versions/node/v22.22.3/bin"
        let stable = root + "/.nvm/versions/node/v22.22.3/lib/node_modules/wrangler"
        let cache = root + "/.npm/_npx/abcdef1234/node_modules/wrangler"
        for package in [stable, cache] {
            try fm.createDirectory(atPath: package + "/bin", withIntermediateDirectories: true)
            try Data(#"{"name":"wrangler","version":"4.160.0"}"#.utf8).write(to: URL(fileURLWithPath: package + "/package.json"))
            fm.createFile(atPath: package + "/bin/wrangler.js", contents: Data(), attributes: [.posixPermissions: 0o700])
        }
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bin + "/wrangler", withDestinationPath: stable + "/bin/wrangler.js")
        let found = Discovery.wranglers(home: root, environment: ["PATH": "/untrusted"], manual: nil)
        #expect(found.first?.path == stable + "/bin/wrangler.js")
        #expect(found.first?.source == .installed)
        #expect(found.last?.source == .npmCache)
        #expect(!Discovery.directories(home: root, environment: ["PATH": "/untrusted"]).contains("/untrusted"))
        #expect(Discovery.wranglers(home: root, environment: [:], manual: "/chosen/missing").map(\.path) == ["/chosen/missing"])
        // A trusted bin symlink must not cause automatic execution in arbitrary project directories.
        let outside = root + "/untrusted-project/node_modules/wrangler"
        try fm.createDirectory(atPath: outside + "/bin", withIntermediateDirectories: true)
        try Data(#"{"name":"wrangler"}"#.utf8).write(to: URL(fileURLWithPath: outside + "/package.json"))
        fm.createFile(atPath: outside + "/bin/wrangler.js", contents: Data(), attributes: [.posixPermissions: 0o700])
        try fm.removeItem(atPath: bin + "/wrangler")
        try fm.createSymbolicLink(atPath: bin + "/wrangler", withDestinationPath: outside + "/bin/wrangler.js")
        #expect(Discovery.wranglers(home: root, environment: [:], manual: nil).allSatisfy { $0.source == .npmCache })
        #expect(!Discovery.trustedNode(root + "/node", home: root))
    }
    @Test func manualFailureDoesNotFallBackAndUnsafeCacheIsRejected() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner()
        let controller = await ready(fake, root: root, node: node, cli: root + "/missing")
        #expect(controller.installation == nil && controller.status.contains("Manual paths retained"))
        let package = root + "/.npm/_npx/12345678/node_modules/wrangler"
        try FileManager.default.createDirectory(atPath: package, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: package + "/bin", withDestinationPath: root)
        try Data(#"{"name":"cf"}"#.utf8).write(to: URL(fileURLWithPath: package + "/package.json"))
        #expect(Discovery.wranglers(home: root, environment: [:], manual: nil).isEmpty)
        let outside = root + "/arbitrary-project/node_modules/wrangler"
        try FileManager.default.createDirectory(atPath: outside + "/bin", withIntermediateDirectories: true)
        try Data(#"{"name":"wrangler"}"#.utf8).write(to: URL(fileURLWithPath: outside + "/package.json"))
        FileManager.default.createFile(atPath: outside + "/bin/wrangler.js", contents: Data(), attributes: [.posixPermissions: 0o700])
        let linked = root + "/.npm/_npx/abcdef1234"
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: root + "/arbitrary-project")
        #expect(Discovery.wranglers(home: root, environment: [:], manual: nil).isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: cli))
    }
    @Test func installedWranglerWithAnotherRuntimeWinsOverCache() async throws {
        let (root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        let nodes = ["v22.22.3", "v24.1.0"].map { root + "/.nvm/versions/node/" + $0 + "/bin/node" }
        for node in nodes {
            try fm.createDirectory(atPath: URL(fileURLWithPath: node).deletingLastPathComponent().path, withIntermediateDirectories: true)
            fm.createFile(atPath: node, contents: Data([0xcf, 0xfa, 0xed, 0xfe]), attributes: [.posixPermissions: 0o700])
        }
        let stable = root + "/.nvm/versions/node/v22.22.3/lib/node_modules/wrangler"
        let cache = root + "/.npm/_npx/12345678/node_modules/wrangler"
        for package in [stable, cache] {
            try fm.createDirectory(atPath: package + "/bin", withIntermediateDirectories: true)
            try Data(#"{"name":"wrangler"}"#.utf8).write(to: URL(fileURLWithPath: package + "/package.json"))
            fm.createFile(atPath: package + "/bin/wrangler.js", contents: Data(), attributes: [.posixPermissions: 0o700])
        }
        try fm.createSymbolicLink(atPath: URL(fileURLWithPath: nodes[0]).deletingLastPathComponent().path + "/wrangler", withDestinationPath: stable + "/bin/wrangler.js")
        let fake = FakeRunner(); await fake.failVersionPair(node: nodes[0], cli: stable + "/bin/wrangler.js")
        let controller = CLIController(runner: fake, environment: ["HOME": root], directory: root)
        await controller.check()
        #expect(controller.installation?.wrangler == stable + "/bin/wrangler.js")
        #expect(controller.installation?.node == nodes[1])
        #expect(controller.installation?.source == .installed)
    }
    @Test func statusParserTreatsAuthAndTransientFailuresDifferently() {
        #expect(ProfilePolicy.identity(CommandResult(status: 1, output: #"{"loggedIn":false}"#)).0 == .reauthenticationNeeded)
        #expect(ProfilePolicy.identity(CommandResult(status: 1, output: "Authentication error [code: 10000]")).0 == .reauthenticationNeeded)
        #expect(ProfilePolicy.identity(CommandResult(status: 1, output: "ENOTFOUND")).0 == .unknown)
        #expect(ProfilePolicy.identity(CommandResult(status: 1, output: "Network unavailable\n{\"loggedIn\":false}")).0 == .unknown)
        #expect(ProfilePolicy.identity(CommandResult(status: 0, output: #"{"loggedIn":true}"#, timedOut: true)).0 == .unknown)
        #expect(ProfilePolicy.catalogue("unexpected table") == nil)
        #expect(ProfilePolicy.identity(CommandResult(status: 1, output: "} malformed {")).0 == .unknown)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WRANGLER_BAR_TEST_NODE"] != nil))
    func nativeFakeCLICompletesNamedBrowserCallbackWithoutTTY() async throws {
        let (root, _, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let node = ProcessInfo.processInfo.environment["WRANGLER_BAR_TEST_NODE"]!
        let script = #"""
        const fs=require('node:fs'),http=require('node:http');
        const a=process.argv.slice(2), p=process.env.CLOUDFLARE_AUTH_PROFILE;
        if(a.join(' ')==='--version'){console.log('4.160.0');process.exit(0)}
        if(a.join(' ')==='auth create --help'){console.log('--browser --callback-host');process.exit(0)}
        if(p==='invalid;selector'){console.error('Invalid profile name');process.exit(1)}
        if(a.join(' ')==='auth list'){console.log('│ Profile │ Bound Directories │\n│ alpha │ /example/a │\n│ beta │ /example/b │\n│ gamma │ - │');process.exit(0)}
        if(a.join(' ')==='whoami --json'){
          if(p==='gamma'){console.error('Network unavailable');process.exit(1)}
          const ok=p==='alpha'||(p==='beta'&&fs.existsSync('completed-beta'));
          console.log(JSON.stringify({loggedIn:ok,tokenPermissions:ok?[p==='alpha'?'account:read':'workers:write']:[]}));
          process.exit(ok?0:1);
        }
        if(a.join(' ')!=='auth create beta --browser=true'||p!=='beta'||process.stdin.isTTY)process.exit(91);
        console.log('SENSITIVE_FIXTURE_OUTPUT');console.error('SENSITIVE_FIXTURE_OUTPUT');
        const server=http.createServer((req,res)=>{
          if(req.url!=='/callback?code=fixture'){res.statusCode=400;res.end();return}
          fs.writeFileSync('completed-beta','fixture completed');res.end('ok');
          server.close(()=>process.exit(0));
        });
        server.on('error',e=>{fs.writeFileSync('fixture-error-code',e.code);process.exit(92)});
        server.listen(0,'127.0.0.1',()=>{
          http.get('http://127.0.0.1:'+server.address().port+'/callback?code=fixture',res=>res.resume());
        });
        setTimeout(()=>process.exit(93),5000).unref();
        """#
        try Data(script.utf8).write(to: URL(fileURLWithPath: cli))
        let controller = CLIController(environment: ["HOME": root], directory: root)
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        #expect(controller.installation != nil)
        await controller.loadProfiles(); await controller.refresh()
        let others = controller.profiles.filter { $0.name != "beta" }
        await controller.signIn(profile: "beta")
        #expect(controller.profiles.first { $0.name == "beta" }?.state == .signedIn)
        #expect(controller.profiles.first { $0.name == "beta" }?.scopes == ["workers:write"])
        #expect(controller.profiles.filter { $0.name != "beta" } == others)
        #expect(FileManager.default.fileExists(atPath: root + "/completed-beta"))
        #expect(!String(describing: controller.profiles).contains("SENSITIVE_FIXTURE_OUTPUT"))
    }
    @Test func nativeProcessDiscardsLoginOutputAndCanCancel() async throws {
        let (root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let runner = ProcessRunner()
        let result = await runner.run(Command(executable: "/bin/sh", arguments: ["-c", "printf SENSITIVE_FIXTURE; printf SENSITIVE_FIXTURE >&2"], environment: ["PATH": "/usr/bin:/bin"], directory: root, capture: false, timeout: 2))
        #expect(result.status == 0 && result.output.isEmpty)
        let task = Task { await runner.run(Command(executable: "/bin/sleep", arguments: ["10"], environment: [:], directory: root, capture: false, timeout: 15)) }
        try await Task.sleep(for: .milliseconds(100)); runner.cancel()
        let cancelled = await task.value
        #expect(cancelled.cancelled)
    }
}
