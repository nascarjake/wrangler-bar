import Foundation
import Testing
@testable import WranglerBarCore

actor FakeRunner: CommandRunning {
    var commands: [Command] = []
    var nodeVersion = "v22.22.3"
    var cliVersion = "4.160.0"
    var deviceSupported = true
    var loginResult: Int32 = 0
    var holdLogin = false
    var waiting: CheckedContinuation<CommandResult, Never>?
    nonisolated func cancel() {}
    func configure(node: String = "v22.22.3", cli: String = "4.160.0", device: Bool = true, result: Int32 = 0, hold: Bool = false) {
        nodeVersion = node; cliVersion = cli; deviceSupported = device; loginResult = result; holdLogin = hold
    }
    func run(_ command: Command) async -> CommandResult {
        commands.append(command)
        let args = command.arguments.first?.hasSuffix("wrangler") == true ? Array(command.arguments.dropFirst()) : command.arguments
        if args == ["--version"] {
            return CommandResult(status: 0, output: command.arguments.count == 1 ? nodeVersion : cliVersion)
        }
        if args == ["login", "--help"] { return CommandResult(status: 0, output: deviceSupported ? "--device --scopes-list" : "--browser") }
        if holdLogin { return await withCheckedContinuation { waiting = $0 } }
        return CommandResult(status: loginResult, output: "DO_NOT_DISPLAY_DEVICE_CODE")
    }
    func release() { waiting?.resume(returning: CommandResult(status: loginResult)); waiting = nil }
}

@Suite(.serialized) @MainActor
struct CoreTests {
    func fixture() throws -> (String, String, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for name in ["node", "wrangler"] {
            FileManager.default.createFile(atPath: root + "/" + name, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o700])
        }
        return (root, root + "/node", root + "/wrangler")
    }
    @Test func versionsAndFinderDiscovery() {
        #expect(Version("v20.18.0")?.supportsNode == false)
        #expect(Version("v22.22.3")?.supportsNode == true)
        #expect(Version("4.118.0")?.supportsWrangler == false)
        #expect(Version("4.119.0")?.supportsWrangler == true)
        #expect(Version("unexpected output") == nil)
        let dirs = Discovery.directories(home: "/example", environment: ["PATH": "/usr/bin:relative:/usr/bin"])
        #expect(dirs.contains("/opt/homebrew/bin"))
        #expect(dirs.contains("/example/.volta/bin"))
        #expect(dirs.filter { $0 == "/usr/bin" }.count == 1)
        #expect(!dirs.contains("relative"))
    }
    @Test func stripsCredentialAndInjectionEnvironment() {
        let env = Discovery.safeEnvironment(base: ["HOME": "/example", "PATH": "/usr/bin", "CLOUDFLARE_API_TOKEN": "secret", "WRANGLER_PROFILE": "other", "NODE_OPTIONS": "injected", "BROWSER": "other"], node: "/custom/bin/node")
        #expect(env["CLOUDFLARE_API_TOKEN"] == nil)
        #expect(env["WRANGLER_PROFILE"] == nil)
        #expect(env["NODE_OPTIONS"] == nil)
        #expect(env["BROWSER"] == nil)
        #expect(env["PATH"]?.hasPrefix("/custom/bin:") == true)
    }
    @Test func readinessAndDefaultLoginDiscardOutput() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner()
        let controller = CLIController(runner: fake, directory: root)
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        #expect(controller.installation?.wranglerVersion == Version("4.160.0"))
        #expect(await fake.commands.count == 3) // No authentication during readiness.
        await controller.signIn(profile: "")
        let commands = await fake.commands
        #expect(commands.last?.arguments == [cli, "login", "--device"])
        #expect(commands.last?.capture == false)
        #expect(commands.last?.environment["WRANGLER_LOG_PATH"] == root + "/discard.log")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root + "/discard.log") == "/dev/null")
        #expect(!controller.status.contains("DO_NOT_DISPLAY"))
        #expect(controller.status == "Wrangler reports sign-in completed")
    }
    @Test(arguments: ["4.119.0", "4.141.0", "4.160.0"])
    func namedProfilesNeverStartLoginOrFallBack(cliVersion: String) async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner(); await fake.configure(cli: cliVersion)
        let controller = CLIController(runner: fake, directory: root)
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        #expect(controller.installation != nil)
        let count = await fake.commands.count
        await controller.signIn(profile: "personal")
        #expect(await fake.commands.count == count)
        #expect(!controller.busy)
        #expect(controller.status == "Named profiles require Terminal · See named-profile help")
        #expect(LoginPolicy.deviceArguments(profile: "personal") == nil)
        #expect(LoginPolicy.deviceArguments(profile: "") == ["login", "--device"])
    }
    @Test func legacyNamedProfileAlsoBlocksBeforeReadiness() async throws {
        let fake = FakeRunner()
        let controller = CLIController(runner: fake)
        await controller.signIn(profile: "legacy-name")
        #expect(await fake.commands.isEmpty)
        #expect(controller.status.contains("Named profiles require Terminal"))
    }
    @Test func oldNodeAndMissingDeviceFailClosed() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner(); await fake.configure(node: "v20.18.0")
        let controller = CLIController(runner: fake, directory: root)
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        await controller.signIn(profile: "")
        #expect(controller.installation == nil)
        #expect(await fake.commands.count == 1)
        await fake.configure(cli: "4.118.0")
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        #expect(controller.installation == nil)
        await fake.configure(device: false)
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        #expect(controller.installation == nil)
    }
    @Test func duplicateLoginAndFailure() async throws {
        let (root, node, cli) = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let fake = FakeRunner(); await fake.configure(result: 1, hold: true)
        let controller = CLIController(runner: fake, directory: root)
        await controller.check(nodeOverride: node, wranglerOverride: cli)
        let task = Task { await controller.signIn(profile: "") }
        while !controller.busy { await Task.yield() }
        await controller.signIn(profile: "")
        while await fake.waiting == nil { await Task.yield() }
        #expect(await fake.commands.filter { $0.arguments == [cli, "login", "--device"] }.count == 1)
        await fake.release(); await task.value
        #expect(!controller.busy)
        #expect(controller.status.contains("failed"))
    }
    @Test func realProcessRunnerDiscardsLoginOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let command = Command(executable: "/bin/sh", arguments: ["-c", "printf fake-device-code; printf fake-stderr >&2"], environment: ["PATH": "/usr/bin:/bin"], directory: root, capture: false, timeout: 2)
        let result = await ProcessRunner().run(command)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }
}
