import Foundation

public struct Version: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init?(_ output: String) {
        let pattern = #"(?:^|\s)v?(\d+)\.(\d+)\.(\d+)(?:\s|$)"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        let numbers = output[range].trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "").split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }
    public static func < (a: Version, b: Version) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
    public var description: String { "\(major).\(minor).\(patch)" }
    public var supportsNode: Bool { self >= Version("22.13.0")! }
    public var supportsWrangler: Bool { self >= Version("4.119.0")! }
}

public struct Command: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String
    public let capture: Bool
    public let timeout: TimeInterval
}

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String = "") { self.status = status; self.output = output }
}

public protocol CommandRunning: Sendable {
    func run(_ command: Command) async -> CommandResult
    func cancel()
}

/// Captures only readiness commands. Authentication output goes straight to /dev/null.
public final class ProcessRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var active: Process?
    public init() {}
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        if let active, active.isRunning { active.terminate() }
    }
    public func run(_ command: Command) async -> CommandResult {
        await Task.detached { self.perform(command) }.value
    }
    private func perform(_ command: Command) -> CommandResult {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.environment = command.environment
            process.currentDirectoryURL = URL(fileURLWithPath: command.directory)
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = command.capture ? pipe : FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            lock.lock(); active = process; lock.unlock()
            defer { lock.lock(); active = nil; lock.unlock() }
            do { try process.run() } catch { return CommandResult(status: -1) }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + command.timeout, execute: timeout)
            // Small version/help responses; drain concurrently with the child to avoid pipe deadlock.
            var data = Data()
            if command.capture {
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if data.count < 65_536 { data.append(chunk.prefix(65_536 - data.count)) }
                }
            }
            process.waitUntilExit()
            timeout.cancel()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

public struct Installation: Sendable, Equatable {
    public let node: String
    public let wrangler: String
    public let nodeVersion: Version
    public let wranglerVersion: Version
}

public enum LoginPolicy {
    /// Wrangler reserves `login --device` for its default profile. Named profiles
    /// use `auth create NAME`, whose documented flow currently needs Terminal.
    public static func deviceArguments(profile: String) -> [String]? {
        profile.isEmpty ? ["login", "--device"] : nil
    }
}

public enum Discovery {
    /// Finder does not inherit shell startup files. Search installed locations without sourcing them.
    public static func directories(home: String, environment: [String: String]) -> [String] {
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.volta/bin",
                  home + "/.local/share/mise/shims", home + "/.asdf/shims",
                  home + "/Library/pnpm", "/usr/bin", "/bin"]
        let roots = [(environment["NVM_DIR"] ?? home + "/.nvm") + "/versions/node",
                     home + "/.local/share/fnm/node-versions", home + "/Library/Application Support/fnm/node-versions"]
        for root in roots {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for name in names.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                paths.append(root + "/" + name + (root.hasSuffix("/node") ? "/bin" : "/installation/bin"))
            }
        }
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    public static func safeEnvironment(base: [String: String], node: String) -> [String: String] {
        // Pass a small explicit environment: no ambient Cloudflare credentials, Node injection, or profile.
        let allowed = ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SHELL"]
        var result = base.filter { allowed.contains($0.key) }
        let paths = directories(home: base["HOME"] ?? NSHomeDirectory(), environment: base)
        result["PATH"] = ([URL(fileURLWithPath: node).deletingLastPathComponent().path] + paths).joined(separator: ":")
        result["WRANGLER_SEND_METRICS"] = "false"
        result["NO_COLOR"] = "1"
        return result
    }
}

@MainActor
public final class CLIController {
    public private(set) var busy = false
    public private(set) var installation: Installation?
    public private(set) var status = "Check tools to get started"
    public var changed: (() -> Void)?
    private let runner: any CommandRunning
    private let environment: [String: String]
    private let directory: String
    public init(runner: any CommandRunning = ProcessRunner(), environment: [String: String] = ProcessInfo.processInfo.environment,
                directory: String? = nil) {
        self.runner = runner; self.environment = environment
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("WranglerBar-" + UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Wrangler appends a log directory unless the path ends in .log.
        try? FileManager.default.createSymbolicLink(atPath: self.directory + "/discard.log", withDestinationPath: "/dev/null")
    }
    private func command(_ path: String, _ args: [String], node: String, capture: Bool = true, timeout: TimeInterval = 10) -> Command {
        var env = Discovery.safeEnvironment(base: environment, node: node)
        env["WRANGLER_LOG_PATH"] = directory + "/discard.log"
        // npm's Wrangler entry point is JavaScript. Run it directly with the checked Node,
        // so cancellation reaches the CLI rather than leaving a shell wrapper polling.
        return Command(executable: node, arguments: path == node ? args : [path] + args, environment: env,
                directory: directory, capture: capture, timeout: timeout)
    }
    public func check(nodeOverride: String? = nil, wranglerOverride: String? = nil) async {
        guard !busy else { return }
        busy = true; installation = nil; status = "Checking installed tools…"; changed?()
        defer { busy = false; changed?() }
        let dirs = Discovery.directories(home: environment["HOME"] ?? NSHomeDirectory(), environment: environment)
        let nodes = nodeOverride.map { [$0] } ?? dirs.map { $0 + "/node" }
        let wranglers = wranglerOverride.map { [$0] } ?? dirs.map { $0 + "/wrangler" }
        var nodeFound = false
        for node in nodes where FileManager.default.isExecutableFile(atPath: node) {
            let result = await runner.run(command(node, ["--version"], node: node))
            guard result.status == 0, let nodeVersion = Version(result.output), nodeVersion.supportsNode else { continue }
            nodeFound = true
            for cli in wranglers where FileManager.default.isExecutableFile(atPath: cli) {
                let result = await runner.run(command(cli, ["--version"], node: node))
                guard result.status == 0, let version = Version(result.output), version.supportsWrangler else { continue }
                let help = await runner.run(command(cli, ["login", "--help"], node: node))
                guard help.status == 0, help.output.contains("--device") else { continue }
                installation = Installation(node: node, wrangler: cli, nodeVersion: nodeVersion, wranglerVersion: version)
                status = "Ready · Wrangler \(version) · Node \(nodeVersion)"
                return
            }
        }
        status = nodeFound ? "Choose Wrangler 4.119+ with device login" : "Choose Node.js 22.13+ (a supported LTS is recommended)"
    }
    public func signIn(profile: String) async {
        guard !busy else { return }
        guard let args = LoginPolicy.deviceArguments(profile: profile) else {
            status = "Named profiles require Terminal · See named-profile help"; changed?(); return
        }
        guard let installation else { return }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: directory + "/discard.log")) == "/dev/null" else {
            status = "Cannot safely discard CLI logs · Restart the app"; changed?(); return
        }
        busy = true; status = "Waiting for Cloudflare approval in your browser…"; changed?()
        defer { busy = false; changed?() }
        let result = await runner.run(command(installation.wrangler, args, node: installation.node, capture: false, timeout: 330))
        status = result.status == 0 ? "Wrangler reports sign-in completed" : "Sign-in stopped or failed · See Help to retry"
    }
    public func cancel() { runner.cancel() }
}
