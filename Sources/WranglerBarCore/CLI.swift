import Foundation
import Darwin

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
    public var supportsNode: Bool { major % 2 == 0 && self >= Version("22.13.0")! }
    public var supportsWrangler: Bool { self >= Version("4.160.0")! }
}

public struct Command: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String
    public let capture: Bool
    public let timeout: TimeInterval
    public var captureErrors: Bool = false
}

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let cancelled: Bool
    public let timedOut: Bool
    public init(status: Int32, output: String = "", cancelled: Bool = false, timedOut: Bool = false) {
        self.status = status; self.output = output; self.cancelled = cancelled; self.timedOut = timedOut
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: Command) async -> CommandResult
    func cancel()
}

/// Metadata is held briefly in memory. Every login's stdout and stderr are discarded.
public final class ProcessRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var active: Process?
    private var epoch = 0
    public init() {}
    private func ticket() -> Int { lock.lock(); defer { lock.unlock() }; return epoch }
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        epoch += 1
        if let active, active.isRunning { active.terminate() }
    }
    public func run(_ command: Command) async -> CommandResult {
        let generation = ticket()
        return await Task.detached { self.perform(command, generation: generation) }.value
    }
    private func perform(_ command: Command, generation: Int) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = URL(fileURLWithPath: command.directory)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = command.capture ? pipe : FileHandle.nullDevice
        process.standardError = command.capture && command.captureErrors ? pipe : FileHandle.nullDevice
        lock.lock()
        guard epoch == generation else { lock.unlock(); return CommandResult(status: -1, cancelled: true) }
        active = process
        do { try process.run() } catch { active = nil; lock.unlock(); return CommandResult(status: -1) }
        lock.unlock()
        defer { lock.lock(); active = nil; lock.unlock() }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let deadline = Date().addingTimeInterval(command.timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + command.timeout, execute: timeout)
        var data = Data()
        if command.capture {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if data.count < 65_536 { data.append(chunk.prefix(65_536 - data.count)) }
            }
        }
        process.waitUntilExit(); timeout.cancel()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
                             cancelled: ticket() != generation, timedOut: Date() >= deadline)
    }
}
