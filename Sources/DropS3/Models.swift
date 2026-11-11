import Foundation
import Security

struct S3Destination: Codable, Equatable, Sendable {
    var endpoint = "http://localhost:3900"
    var region = "garage"
    var bucket = ""
    var prefix = "backups"
    var accessKey = ""

    /// Pasted values often carry a trailing newline or spaces; none of these fields may contain whitespace.
    var sanitized: S3Destination {
        var d = self
        d.endpoint = endpoint.removingWhitespace
        d.region = region.removingWhitespace
        d.bucket = bucket.removingWhitespace
        d.accessKey = accessKey.removingWhitespace
        d.prefix = prefix.filter { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        return d
    }
}

extension String {
    var removingWhitespace: String { filter { !$0.isWhitespace && !$0.isNewline } }
}

enum Frequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, hourly, every6h, every12h, daily, weekly
    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: t("Solo manual", "Manual only")
        case .hourly: t("Cada hora", "Every hour")
        case .every6h: t("Cada 6 horas", "Every 6 hours")
        case .every12h: t("Cada 12 horas", "Every 12 hours")
        case .daily: t("Cada día", "Every day")
        case .weekly: t("Cada semana", "Every week")
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .manual: nil
        case .hourly: 3600
        case .every6h: 6 * 3600
        case .every12h: 12 * 3600
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        }
    }
}

struct BackupConfig: Codable, Equatable, Sendable {
    var folders: [String] = []
    var excludes: [String] = ["node_modules", "vendor", ".DS_Store"]
    var destination = S3Destination()
    var frequency: Frequency = .daily
    var keepCopies = 7
    var encrypt = false

    init() {}

    // Tolerant decoding: configs saved by older versions lack newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackupConfig()
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? d.folders
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? d.excludes
        destination = try c.decodeIfPresent(S3Destination.self, forKey: .destination) ?? d.destination
        frequency = try c.decodeIfPresent(Frequency.self, forKey: .frequency) ?? d.frequency
        keepCopies = try c.decodeIfPresent(Int.self, forKey: .keepCopies) ?? d.keepCopies
        encrypt = try c.decodeIfPresent(Bool.self, forKey: .encrypt) ?? d.encrypt
    }

    var isReady: Bool {
        !folders.isEmpty && !destination.bucket.isEmpty && !destination.accessKey.isEmpty
    }
}

enum RunStatus: String, Codable, Sendable {
    case ok, warnings, failed, cancelled
}

struct FileIssue: Codable, Identifiable, Sendable {
    var id = UUID()
    let path: String
    let message: String
}

struct RunRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    let snapshot: String
    let start: Date
    var end: Date
    var files = 0
    var bytes: Int64 = 0
    var status: RunStatus = .failed
    var issueCount = 0
    var issues: [FileIssue] = []   // capped; issueCount holds the real total
    var message: String?
    var pruned = 0
}

enum BackupPhase: Sendable { case connecting, scanning, uploading, pruning, restoring }

struct BackupProgress: Sendable {
    var phase: BackupPhase
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var current = ""

    var fraction: Double {
        bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal)
            : (filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0)
    }
}

/// File format of an exported configuration. Never contains the S3 secret key or the encryption passphrase.
struct ConfigExport: Codable {
    var drops3 = 1
    var config: BackupConfig

    static func encode(_ config: BackupConfig) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(ConfigExport(config: config))
    }

    /// Returns nil unless the data is a DropS3 export (so a random JSON file can't wipe the settings).
    static func decode(_ data: Data) -> BackupConfig? {
        struct Probe: Decodable { let drops3: Int?; let respaldo: Int?; let config: BackupConfig }   // "respaldo": former app name
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data),
              probe.drops3 != nil || probe.respaldo != nil else { return nil }
        var config = probe.config
        config.destination = config.destination.sanitized
        config.keepCopies = min(365, max(1, config.keepCopies))
        return config
    }
}

// MARK: - Persistence

enum Store {
    static var directory: URL {
        let dir: URL
        if let custom = ProcessInfo.processInfo.environment["DROPS3_CONFIG_DIR"] {
            dir = URL(fileURLWithPath: custom)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = support.appendingPathComponent("DropS3")
            // The app used to be called Respaldo: carry its settings and history over once.
            let legacy = support.appendingPathComponent("Respaldo")
            if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.moveItem(at: legacy, to: dir)
            }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func load<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(type, from: data)
    }

    private static func save<T: Encodable>(_ name: String, _ value: T) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func loadConfig() -> BackupConfig { load("config.json", BackupConfig.self) ?? BackupConfig() }
    static func saveConfig(_ c: BackupConfig) { save("config.json", c) }
    static func loadHistory() -> [RunRecord] { load("history.json", [RunRecord].self) ?? [] }
    static func saveHistory(_ h: [RunRecord]) { save("history.json", Array(h.prefix(100))) }
}

/// The S3 secret key and the encryption passphrase live in the login keychain, never in config.json.
enum Keychain {
    enum Account: String {
        case secret = "s3-secret-key"
        case passphrase = "encryption-passphrase"
        var envOverride: String { self == .secret ? "DROPS3_SECRET" : "DROPS3_PASSPHRASE" }
    }

    private static func base(_ account: Account, service: String = "com.local.drops3") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account.rawValue]
    }

    private static func read(_ query: [String: Any]) -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func get(_ account: Account) -> String {
        if let env = ProcessInfo.processInfo.environment[account.envOverride] { return env }
        if let value = read(base(account)) { return value }
        // Migrate the item saved under the app's former name (Respaldo).
        if let legacy = read(base(account, service: "com.local.respaldo")), !legacy.isEmpty {
            set(legacy, account)
            return legacy
        }
        return ""
    }

    static func set(_ value: String, _ account: Account) {
        SecItemDelete(base(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base(account)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
