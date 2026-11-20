import Foundation

public enum ProfileState: String, Sendable, Codable {
    case signedIn = "Signed in"
    case reauthenticationNeeded = "Reauthentication needed"
    case unknown = "Unknown"
}

public struct ProfileRecord: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public var bindingCount: Int
    public var state: ProfileState = .unknown
    public var scopes: [String] = []
    public var checkedAt: Date?
    public var scopesCheckedAt: Date?
    public var lastSignInAt: Date?
    public var note = "Not checked yet"
    public var registered = true
    public init(name: String, bindingCount: Int = 0) { self.name = name; self.bindingCount = bindingCount }
}

public enum ProfilePolicy {
    public static let selector = "CLOUDFLARE_AUTH_PROFILE"
    public static func valid(_ name: String) -> Bool {
        name == "default" || !["default", "staging"].contains(name.lowercased()) && name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }
    public static func signInArguments(name: String) -> [String]? {
        guard valid(name) else { return nil }
        return name == "default" ? ["login", "--device", "--browser=true"] : ["auth", "create", name, "--browser=true"]
    }
    public static func catalogue(_ output: String) -> [ProfileRecord]? {
        if output.contains("No profiles found") { return [] }
        guard output.contains("Profile"), output.contains("Bound Directories") else { return nil }
        var profiles: [ProfileRecord] = []
        for line in output.components(separatedBy: .newlines) {
            let cols = line.components(separatedBy: "│").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 4, !cols[1].isEmpty, cols[1] != "Profile" else { continue }
            guard valid(cols[1]), !profiles.contains(where: { $0.name == cols[1] }) else { return nil }
            let count = cols[2].components(separatedBy: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.trimmingCharacters(in: .whitespaces) != "-" }.count
            profiles.append(ProfileRecord(name: cols[1], bindingCount: count))
        }
        return profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func identity(_ result: CommandResult) -> (ProfileState, [String], String) {
        if result.cancelled { return (.unknown, [], "Check cancelled") }
        if result.timedOut { return (.unknown, [], "Check timed out; retry when connected") }
        struct Identity: Decodable { let loggedIn: Bool; let tokenPermissions: [String]? }
        let raw = result.output
        let text = raw.lowercased()
        let transient = ["enotfound", "eai_again", "econnreset", "network unavailable", "network unreachable", "fetch failed", "timed out", "timeout"].contains { text.contains($0) }
        // JSON output may be preceded by a CLI warning. No raw output enters the UI or a log.
        var data: Data?
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start <= end {
            data = Data(raw[start...end].utf8)
        }
        if let data, let identity = try? JSONDecoder().decode(Identity.self, from: data) {
            if !identity.loggedIn {
                return transient ? (.unknown, [], "The network prevented authentication verification") :
                    (.reauthenticationNeeded, [], "Wrangler reports this profile is not authenticated")
            }
            if result.status == 0 {
                let scopes = (identity.tokenPermissions ?? []).filter {
                    $0.range(of: #"^[A-Za-z][A-Za-z0-9_]*(?::[A-Za-z][A-Za-z0-9_-]*)?$"#, options: .regularExpression) != nil
                }
                return (.signedIn, Array(Set(scopes)).sorted(), "Verified by Wrangler")
            }
        }
        if transient { return (.unknown, [], "The network prevented authentication verification") }
        if text.contains("authentication error") || text.contains("invalid_grant") || text.contains("token expired") || text.contains("not authenticated") {
            return (.reauthenticationNeeded, [], "Wrangler requires authentication for this profile")
        }
        return (.unknown, [], "Wrangler could not verify status; check the network, permissions, or CLI")
    }
}
