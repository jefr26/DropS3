import Foundation
import CryptoKit

struct RemoteSnapshot: Identifiable, Hashable, Sendable {
    let name: String        // e.g. 2026-11-10T19-30-00Z
    let prefix: String      // full key prefix, ends with "/"
    let encrypted: Bool
    let complete: Bool      // has a manifest
    var id: String { name }

    var date: Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return fmt.date(from: name)
    }
}

struct RestoreResult: Sendable {
    var destination: String
    var files = 0
    var bytes: Int64 = 0
    var issueCount = 0
    var issues: [FileIssue] = []
    var message: String?
    var cancelled = false
    var ok: Bool { message == nil && issueCount == 0 && !cancelled }
}

enum RestoreEngine {
    static func basePrefix(_ config: BackupConfig) -> String {
        let trimmed = config.destination.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }

    /// Snapshots in the destination, newest first.
    static func snapshots(_ client: S3Client, base: String) async throws -> [RemoteSnapshot] {
        var out: [RemoteSnapshot] = []
        for prefix in try await BackupEngine.listSnapshots(client, base: base).reversed() {
            let keys = try await client.list(prefix: prefix + "manifest.json").keys
            let encrypted = keys.contains(prefix + "manifest.json.enc")
            out.append(RemoteSnapshot(name: String(prefix.dropFirst(base.count).dropLast()), prefix: prefix,
                                      encrypted: encrypted,
                                      complete: encrypted || keys.contains(prefix + "manifest.json")))
        }
        return out
    }

    static func run(config: BackupConfig, secret: String, passphrase: String, snapshot: RemoteSnapshot,
                    destination: URL, progress: @escaping @Sendable (BackupProgress) -> Void) async -> RestoreResult {
        var result = RestoreResult(destination: destination.path)
        guard let client = S3Client(config.destination, secret: secret) else {
            result.message = t("La configuración del destino no es válida.", "The destination settings are not valid.")
            return result
        }
        let keys = KeyCache(passphrase: passphrase)
        var state = BackupProgress(phase: .restoring)
        progress(state)

        do {
            // 1. Manifest: the list of files with their expected size and SHA-256.
            let manifest: BackupEngine.Manifest
            do {
                let downloaded = try await client.download(snapshot.prefix + (snapshot.encrypted ? "manifest.json.enc" : "manifest.json"))
                defer { try? FileManager.default.removeItem(at: downloaded) }
                let plain = snapshot.encrypted ? tempFile() : downloaded
                defer { try? FileManager.default.removeItem(at: plain) }
                if snapshot.encrypted {
                    _ = try Crypto.decryptFile(from: downloaded, to: plain, keys: keys)
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                manifest = try decoder.decode(BackupEngine.Manifest.self, from: Data(contentsOf: plain))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                result.message = t("No se pudo leer el manifiesto de la copia: \(error.localizedDescription)", "Couldn't read the backup manifest: \(error.localizedDescription)")
                return result
            }

            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            state.filesTotal = manifest.files.count
            state.bytesTotal = manifest.files.reduce(0) { $0 + $1.size }
            progress(state)
            var lastEmit = Date.distantPast

            // 2. Download, decrypt and verify every file.
            try await withThrowingTaskGroup(of: (BackupEngine.ManifestEntry, String?).self) { group in
                var iterator = manifest.files.makeIterator()
                func add(_ entry: BackupEngine.ManifestEntry) {
                    group.addTask {
                        (entry, try await restoreOne(client, entry, snapshot: snapshot, destination: destination, keys: keys))
                    }
                }
                for _ in 0..<BackupEngine.concurrency { if let entry = iterator.next() { add(entry) } }
                while let (entry, failure) = try await group.next() {
                    try Task.checkCancellation()
                    state.filesDone += 1
                    state.bytesDone += entry.size
                    state.current = entry.path
                    if let failure {
                        result.issueCount += 1
                        if result.issues.count < BackupEngine.maxStoredIssues {
                            result.issues.append(FileIssue(path: entry.path, message: failure))
                        }
                    } else {
                        result.files += 1
                        result.bytes += entry.size
                    }
                    if Date().timeIntervalSince(lastEmit) > 0.1 || state.filesDone == state.filesTotal {
                        lastEmit = Date()
                        progress(state)
                    }
                    if let entry = iterator.next() { add(entry) }
                }
            }
        } catch is CancellationError {
            result.cancelled = true
            result.message = t("Restauración cancelada.", "Restore cancelled.")
        } catch {
            if Task.isCancelled { result.cancelled = true }
            result.message = error.localizedDescription
        }
        return result
    }

    /// Returns nil on success, or the error text.
    private static func restoreOne(_ client: S3Client, _ entry: BackupEngine.ManifestEntry, snapshot: RemoteSnapshot,
                                   destination: URL, keys: KeyCache) async throws -> String? {
        // Never write outside the chosen folder, whatever the manifest says.
        let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return t("Ruta no válida en el manifiesto.", "Invalid path in the manifest.")
        }
        let target = destination.appendingPathComponent(entry.path)
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let downloaded = try await client.download(snapshot.prefix + entry.path + (snapshot.encrypted ? ".enc" : ""))
                defer { try? FileManager.default.removeItem(at: downloaded) }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let partial = target.deletingLastPathComponent().appendingPathComponent(".drops3-\(UUID().uuidString).partial")
                defer { try? FileManager.default.removeItem(at: partial) }

                let actual: (sha256: String, size: Int64)
                if snapshot.encrypted {
                    actual = try Crypto.decryptFile(from: downloaded, to: partial, keys: keys)
                } else {
                    let hash = try BackupEngine.hashFile(downloaded)
                    actual = (hash.sha256, hash.size)
                    try FileManager.default.moveItem(at: downloaded, to: partial)
                }
                guard actual.size == entry.size, actual.sha256 == entry.sha256 else {
                    return t("Verificación fallida: el contenido no coincide con el manifiesto.", "Verification failed: content doesn't match the manifest.")
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: partial)
                } else {
                    try FileManager.default.moveItem(at: partial, to: target)
                }
                // Original permissions and modification date (absent in copies made by older versions).
                var attributes: [FileAttributeKey: Any] = [:]
                if let mode = entry.mode { attributes[.posixPermissions] = NSNumber(value: mode) }
                if let mtime = entry.mtime { attributes[.modificationDate] = Date(timeIntervalSince1970: mtime) }
                if !attributes.isEmpty {
                    try? FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
                }
                return nil
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                let retriable = error is URLError || ((error as? S3Error)?.status ?? 0) >= 500
                guard retriable, attempt < 3 else { break }
                try await Task.sleep(for: .seconds(attempt * 2))
            }
        }
        return lastError?.localizedDescription ?? t("Error desconocido", "Unknown error")
    }

    static func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("drops3-\(UUID().uuidString)")
    }
}
