import Foundation
import CryptoKit

/// Each run creates a full snapshot under `<prefix>/<timestamp>/<folder>/<relative path>`
/// plus a `manifest.json` with the SHA-256 of every file. With encryption on, every object
/// (manifest included) is stored encrypted with an `.enc` suffix.
enum BackupEngine {
    struct Item: Sendable {
        let url: URL
        let key: String
        let display: String
        let size: Int64
        var mode: Int?          // POSIX permissions
        var mtime: Double?      // modification date, seconds since 1970
    }

    struct ManifestEntry: Codable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
        var mode: Int? = nil
        var mtime: Double? = nil
    }

    struct Manifest: Codable {
        let snapshot: String
        let createdAt: Date
        let host: String
        let failedFiles: Int
        var encrypted: Bool?
        let files: [ManifestEntry]
    }

    enum Outcome: Sendable {
        case ok(ManifestEntry)
        case failed(FileIssue, size: Int64)
    }

    struct VerifyError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    static let multipartThreshold: Int64 = 256 << 20
    static let partSize = 64 << 20
    static let concurrency = 4
    static let maxStoredIssues = 500

    // MARK: Run

    static func run(config: BackupConfig, secret: String, passphrase: String = "",
                    progress: @escaping @Sendable (BackupProgress) -> Void) async -> RunRecord {
        let start = Date()
        let snapshot = snapshotName(start)
        var record = RunRecord(snapshot: snapshot, start: start, end: start)

        func finish(_ status: RunStatus, _ message: String? = nil) -> RunRecord {
            record.status = status
            record.message = message
            record.end = Date()
            return record
        }
        func addIssue(_ issue: FileIssue) {
            record.issueCount += 1
            if record.issues.count < maxStoredIssues { record.issues.append(issue) }
        }

        guard !config.folders.isEmpty else { return finish(.failed, t("No hay carpetas seleccionadas.", "No folders selected.")) }
        guard let client = S3Client(config.destination, secret: secret) else {
            return finish(.failed, t("La configuración del destino no es válida (endpoint o bucket).", "The destination settings are not valid (endpoint or bucket)."))
        }
        let trimmed = config.destination.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let base = trimmed.isEmpty ? "" : trimmed + "/"
        let root = base + snapshot + "/"

        let encryption: Encryption?
        if config.encrypt {
            guard !passphrase.isEmpty else {
                return finish(.failed, t("El cifrado está activado pero falta la clave de cifrado.", "Encryption is on but the encryption passphrase is missing."))
            }
            let salt = Crypto.randomBytes(16)
            guard let master = try? Crypto.deriveMaster(passphrase: passphrase, salt: salt) else {
                return finish(.failed, t("No se pudo derivar la clave de cifrado.", "Couldn't derive the encryption key."))
            }
            encryption = Encryption(master: master, salt: salt)
        } else {
            encryption = nil
        }

        do {
            progress(BackupProgress(phase: .connecting))
            do { try await client.checkBucket() } catch {
                if Task.isCancelled { throw CancellationError() }
                return finish(.failed, t("No se pudo conectar con el destino: \(error.localizedDescription)", "Couldn't connect to the destination: \(error.localizedDescription)"))
            }

            progress(BackupProgress(phase: .scanning))
            let (items, scanIssues) = try scan(config, root: root)
            scanIssues.forEach(addIssue)

            var state = BackupProgress(phase: .uploading)
            state.filesTotal = items.count
            state.bytesTotal = items.reduce(0) { $0 + $1.size }
            progress(state)

            var entries: [ManifestEntry] = []
            entries.reserveCapacity(items.count)
            var lastEmit = Date.distantPast

            try await withThrowingTaskGroup(of: Outcome.self) { group in
                var iterator = items.makeIterator()
                for _ in 0..<concurrency {
                    if let item = iterator.next() { group.addTask { try await uploadOne(client, item, encryption) } }
                }
                while let outcome = try await group.next() {
                    try Task.checkCancellation()
                    state.filesDone += 1
                    switch outcome {
                    case .ok(let entry):
                        entries.append(entry)
                        record.files += 1
                        record.bytes += entry.size
                        state.bytesDone += entry.size
                        state.current = entry.path
                    case .failed(let issue, let size):
                        addIssue(issue)
                        state.bytesDone += size
                    }
                    if Date().timeIntervalSince(lastEmit) > 0.1 || state.filesDone == state.filesTotal {
                        lastEmit = Date()
                        progress(state)
                    }
                    if let item = iterator.next() { group.addTask { try await uploadOne(client, item, encryption) } }
                }
            }

            // Manifest: written last, so its presence marks a finished snapshot.
            let manifest = Manifest(snapshot: snapshot, createdAt: start,
                                    host: Host.current().localizedName ?? "mac",
                                    failedFiles: record.issueCount, encrypted: encryption != nil,
                                    files: entries.sorted { $0.path < $1.path })
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let plain = RestoreEngine.tempFile()
                let sealed = RestoreEngine.tempFile()
                defer {
                    try? FileManager.default.removeItem(at: plain)
                    try? FileManager.default.removeItem(at: sealed)
                }
                try encoder.encode(manifest).write(to: plain)
                if let encryption {
                    _ = try Crypto.encryptFile(from: plain, to: sealed, encryption: encryption)
                    _ = try await store(client, file: sealed, key: root + "manifest.json.enc")
                } else {
                    _ = try await store(client, file: plain, key: root + "manifest.json")
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                addIssue(FileIssue(path: "manifest.json", message: t("No se pudo guardar el manifiesto: \(error.localizedDescription)", "Couldn't store the manifest: \(error.localizedDescription)")))
            }

            // Retention: only prune after a clean run, so a bad copy never displaces a good one.
            if record.issueCount == 0 {
                progress(BackupProgress(phase: .pruning))
                do {
                    record.pruned = try await prune(client, base: base, keep: max(1, config.keepCopies))
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    addIssue(FileIssue(path: t("retención", "retention"), message: t("No se pudieron borrar copias antiguas: \(error.localizedDescription)", "Couldn't delete old backups: \(error.localizedDescription)")))
                }
            }

            if record.issueCount == 0 { return finish(.ok) }
            return finish(record.files > 0 ? .warnings : .failed,
                          record.files > 0 ? nil : t("No se pudo copiar ningún archivo.", "No file could be backed up."))
        } catch is CancellationError {
            return finish(.cancelled, t("Respaldo cancelado.", "Backup cancelled."))
        } catch {
            return finish(Task.isCancelled ? .cancelled : .failed, error.localizedDescription)
        }
    }

    // MARK: Scan

    static func scan(_ config: BackupConfig, root: String) throws -> ([Item], [FileIssue]) {
        var items: [Item] = []
        var issues: [FileIssue] = []
        var labels = Set<String>()
        let excluder = Excluder(config.excludes)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let fm = FileManager.default

        for folder in config.folders {
            let dir = URL(fileURLWithPath: folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                issues.append(FileIssue(path: folder, message: t("La carpeta no existe o no es accesible.", "The folder doesn't exist or isn't accessible.")))
                continue
            }
            guard fm.isReadableFile(atPath: dir.path), (try? fm.contentsOfDirectory(atPath: dir.path)) != nil else {
                issues.append(FileIssue(path: folder, message: t("Sin permiso para leer la carpeta.", "No permission to read the folder.")))
                continue
            }
            var label = dir.lastPathComponent
            var n = 2
            while labels.contains(label) { label = "\(dir.lastPathComponent)-\(n)"; n += 1 }
            labels.insert(label)

            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: [], errorHandler: { url, error in
                issues.append(FileIssue(path: url.path, message: error.localizedDescription))
                return true
            }) else { continue }

            for case let url as URL in walker {
                try Task.checkCancellation()
                let values = try? url.resourceValues(forKeys: Set(keys))
                // Depth-based, so it is immune to /private/tmp vs /tmp style path differences.
                // NFC: the form other systems and S3 tools expect (macOS hands out decomposed names).
                let rel = url.pathComponents.suffix(walker.level).joined(separator: "/")
                    .precomposedStringWithCanonicalMapping
                if excluder.matches(name: url.lastPathComponent, relative: rel, absolute: url.path) {
                    if values?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
                let attributes = try? fm.attributesOfItem(atPath: url.path)
                items.append(Item(url: url, key: root + label + "/" + rel, display: label + "/" + rel,
                                  size: Int64(values?.fileSize ?? 0),
                                  mode: (attributes?[.posixPermissions] as? NSNumber)?.intValue,
                                  mtime: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970))
            }
        }
        return (items, issues)
    }

    // MARK: Upload + verify

    static func uploadOne(_ client: S3Client, _ item: Item, _ encryption: Encryption?) async throws -> Outcome {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return .ok(try await uploadVerified(client, item, encryption))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                let retriable = error is URLError || ((error as? S3Error)?.status ?? 0) >= 500
                guard retriable, attempt < 3 else { break }
                try await Task.sleep(for: .seconds(attempt * 2))
            }
        }
        return .failed(FileIssue(path: item.url.path, message: lastError?.localizedDescription ?? t("Error desconocido", "Unknown error")),
                       size: item.size)
    }

    static func uploadVerified(_ client: S3Client, _ item: Item, _ encryption: Encryption?) async throws -> ManifestEntry {
        guard let encryption else {
            let stored = try await store(client, file: item.url, key: item.key)
            return ManifestEntry(path: item.display, size: stored.size, sha256: stored.sha256,
                                 mode: item.mode, mtime: item.mtime)
        }
        // Encrypt to a temporary file, then upload + verify that file like any other.
        let sealed = RestoreEngine.tempFile()
        defer { try? FileManager.default.removeItem(at: sealed) }
        let plain = try Crypto.encryptFile(from: item.url, to: sealed, encryption: encryption)
        _ = try await store(client, file: sealed, key: item.key + ".enc")
        return ManifestEntry(path: item.display, size: plain.size, sha256: plain.sha256,
                             mode: item.mode, mtime: item.mtime)
    }

    /// Uploads a file and verifies the stored object. Returns SHA-256 and size of what was uploaded.
    static func store(_ client: S3Client, file: URL, key: String) async throws -> (sha256: String, size: Int64) {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > multipartThreshold
            ? try await storeMultipart(client, file: file, key: key)
            : try await storeSingle(client, file: file, key: key)
    }

    /// Single PUT. The server validates the SHA-256 we sign; afterwards we HEAD the object
    /// and compare size and MD5 (ETag) against what we read from disk.
    static func storeSingle(_ client: S3Client, file: URL, key: String) async throws -> (sha256: String, size: Int64) {
        let local = try hashFile(file)
        try await client.putFile(key, file: file, sha256: local.sha256)
        let remote = try await client.head(key)
        var problem: String?
        if remote.size != local.size {
            problem = t("Verificación fallida: tamaño en destino \(remote.size) ≠ local \(local.size).", "Verification failed: size at destination \(remote.size) ≠ local \(local.size).")
        } else if isMD5(remote.etag), remote.etag.lowercased() != local.md5 {
            problem = t("Verificación fallida: la suma de comprobación no coincide.", "Verification failed: checksum mismatch.")
        }
        if let problem {
            try? await client.delete(key)   // never leave a bad copy in the snapshot
            throw VerifyError(text: problem)
        }
        return (local.sha256, local.size)
    }

    /// Multipart for large files: every part is checked (signed SHA-256 + MD5 ETag), then total size.
    static func storeMultipart(_ client: S3Client, file: URL, key: String) async throws -> (sha256: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let uploadId = try await client.createMultipart(key)
        do {
            var sha = SHA256()
            var etags: [String] = []
            var total: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: partSize), !chunk.isEmpty else { break }
                sha.update(data: chunk)
                total += Int64(chunk.count)
                let etag = try await client.uploadPart(key, uploadId: uploadId, number: etags.count + 1, data: chunk)
                let md5 = Insecure.MD5.hash(data: chunk).map { String(format: "%02x", $0) }.joined()
                if isMD5(etag), etag.lowercased() != md5 {
                    throw VerifyError(text: t("Verificación fallida en la parte \(etags.count + 1).", "Verification failed on part \(etags.count + 1)."))
                }
                etags.append(etag)
            }
            try await client.completeMultipart(key, uploadId: uploadId, etags: etags)
            let remote = try await client.head(key)
            guard remote.size == total else {
                try? await client.delete(key)
                throw VerifyError(text: t("Verificación fallida: tamaño en destino \(remote.size) ≠ local \(total).", "Verification failed: size at destination \(remote.size) ≠ local \(total)."))
            }
            return (sha.finalize().map { String(format: "%02x", $0) }.joined(), total)
        } catch {
            await client.abortMultipart(key, uploadId: uploadId)
            throw error
        }
    }

    static func hashFile(_ url: URL) throws -> (sha256: String, md5: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var size: Int64 = 0
        while true {
            let done: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return true }
                sha.update(data: chunk)
                md5.update(data: chunk)
                size += Int64(chunk.count)
                return false
            }
            if done { break }
        }
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(),
                md5.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    static func isMD5(_ etag: String) -> Bool {
        etag.count == 32 && etag.allSatisfy(\.isHexDigit)
    }

    // MARK: Retention

    static func isSnapshotName(_ name: String) -> Bool {
        name.wholeMatch(of: #/\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z/#) != nil
    }

    static func listSnapshots(_ client: S3Client, base: String) async throws -> [String] {
        var prefixes: [String] = []
        var token: String?
        repeat {
            let page = try await client.list(prefix: base, delimiter: "/", token: token)
            prefixes += page.prefixes
            token = page.nextToken
        } while token != nil
        // Only folders named like our snapshots are ever considered — nothing else in the bucket is touched.
        return prefixes.filter { isSnapshotName(String($0.dropFirst(base.count).dropLast())) }.sorted()
    }

    /// Deletes the oldest snapshots beyond `keep`. Returns how many were removed.
    static func prune(_ client: S3Client, base: String, keep: Int) async throws -> Int {
        let snapshots = try await listSnapshots(client, base: base)
        let doomed = snapshots.dropLast(keep)
        for prefix in doomed {
            // Re-list from the start until empty: safe even if the server's pagination shifts while deleting.
            while true {
                try Task.checkCancellation()
                let page = try await client.list(prefix: prefix)
                if page.keys.isEmpty { break }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var iterator = page.keys.makeIterator()
                    for _ in 0..<8 {
                        if let key = iterator.next() { group.addTask { try await client.delete(key) } }
                    }
                    while try await group.next() != nil {
                        if let key = iterator.next() { group.addTask { try await client.delete(key) } }
                    }
                }
            }
        }
        return doomed.count
    }

    static func snapshotName(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return fmt.string(from: date)
    }
}

/// Exclusion patterns:
///  - `node_modules`, `*.log`  → matches any file or folder with that name (glob)
///  - `src/tmp`, `**/cache/*`  → glob against the path relative to the backed-up folder
///  - `/Users/me/big`          → absolute path (and everything below it)
struct Excluder {
    private let names: [String]
    private let relatives: [String]
    private let absolutes: [String]

    init(_ patterns: [String]) {
        var names: [String] = [], relatives: [String] = [], absolutes: [String] = []
        for raw in patterns {
            var p = raw.trimmingCharacters(in: .whitespaces)
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            if p.isEmpty { continue }
            if p.hasPrefix("/") { absolutes.append(p) }
            else if p.contains("/") { relatives.append(p) }
            else { names.append(p) }
        }
        self.names = names
        self.relatives = relatives
        self.absolutes = absolutes
    }

    func matches(name: String, relative: String, absolute: String) -> Bool {
        names.contains { fnmatch($0, name, 0) == 0 }
            || relatives.contains { fnmatch($0, relative, 0) == 0 }
            || absolutes.contains { absolute == $0 || absolute.hasPrefix($0 + "/") }
    }
}
