import Foundation

public enum ToolSource: String, Sendable { case manual = "Manual path", installed = "Installed", npmCache = "npm cache · temporary" }
public struct ToolCandidate: Sendable, Equatable {
    public let path: String
    public let source: ToolSource
    public init(path: String, source: ToolSource) { self.path = path; self.source = source }
}
public struct Installation: Sendable, Equatable {
    public let node: String
    public let wrangler: String
    public let nodeVersion: Version
    public let wranglerVersion: Version
    public let source: ToolSource
}
public enum Discovery {
    private static func trustedRoots(home: String) -> [String] {
        [home + "/.nvm/versions/node/", home + "/.local/share/fnm/node-versions/",
         home + "/Library/Application Support/fnm/node-versions/", "/opt/homebrew/", "/usr/local/", "/usr/bin/", "/bin/"]
    }
    public static func trustedNode(_ path: String, home: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return trustedRoots(home: home).contains { resolved.hasPrefix($0) } && isNativeExecutable(resolved)
    }
    public static func isNativeExecutable(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let magic = Array((try? handle.read(upToCount: 4)) ?? Data())
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca]].contains(magic)
    }
    /// Only known installed locations. PATH entries outside these roots are never executed automatically.
    public static func directories(home: String, environment: [String: String]) -> [String] {
        let fm = FileManager.default
        var versions: [(String, Version)] = []
        let roots = [(home + "/.nvm/versions/node", "/bin"),
                     (home + "/.local/share/fnm/node-versions", "/installation/bin"),
                     (home + "/Library/Application Support/fnm/node-versions", "/installation/bin")]
        for (root, suffix) in roots {
            for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []) {
                if let version = Version(name), version.supportsNode { versions.append((root + "/" + name + suffix, version)) }
            }
        }
        versions.sort { a, b in
            if a.1.major == 22 && b.1.major != 22 { return true }
            if b.1.major == 22 && a.1.major != 22 { return false }
            return a.1 > b.1
        }
        return versions.map(\.0) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }
    private static func npmEntry(_ path: String, requiredRoot: String? = nil) -> String? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.lastPathComponent == "wrangler.js", url.deletingLastPathComponent().lastPathComponent == "bin",
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let package = url.deletingLastPathComponent().deletingLastPathComponent()
        if let requiredRoot {
            let root = URL(fileURLWithPath: requiredRoot).resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(root) else { return nil }
        }
        guard let data = try? Data(contentsOf: package.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["name"] as? String == "wrangler" else { return nil }
        return url.path
    }
    public static func wranglers(home: String, environment: [String: String], manual: String?) -> [ToolCandidate] {
        if let manual { return [ToolCandidate(path: URL(fileURLWithPath: manual).resolvingSymlinksInPath().path, source: .manual)] }
        var result: [ToolCandidate] = []
        for dir in directories(home: home, environment: environment) {
            if let entry = npmEntry(dir + "/wrangler"), trustedRoots(home: home).contains(where: { entry.hasPrefix($0) }) {
                result.append(ToolCandidate(path: entry, source: .installed))
            }
        }
        // Bounded fallback in npm's known cache layout, never a recursive project scan.
        let cache = home + "/.npm/_npx"
        let expectedCache = URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/.npm/_npx"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? []).filter {
            $0.range(of: #"^[a-f0-9]{8,64}$"#, options: .regularExpression) != nil
        }.sorted().prefix(64)
        for name in names {
            let root = cache + "/" + name
            let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            // A cache-key symlink must not turn this bounded scan into project discovery.
            guard resolvedRoot == expectedCache + "/" + name else { continue }
            if let entry = npmEntry(root + "/node_modules/wrangler/bin/wrangler.js", requiredRoot: root) {
                result.append(ToolCandidate(path: entry, source: .npmCache))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
    }
    public static func safeEnvironment(base: [String: String], node: String) -> [String: String] {
        let allowed = ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"]
        var result = base.filter { allowed.contains($0.key) }
        result["PATH"] = ([URL(fileURLWithPath: node).deletingLastPathComponent().path] + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        result["WRANGLER_SEND_METRICS"] = "false"
        result["WRANGLER_SEND_ERROR_REPORTS"] = "false"
        result["WRANGLER_LOG_SANITIZE"] = "true"
        result["NO_COLOR"] = "1"
        return result
    }
}
