import Foundation
import SwiftUI
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var config: BackupConfig {
        didSet {
            let clean = config.destination.sanitized
            if clean != config.destination { config.destination = clean; return }
            if config != oldValue { Store.saveConfig(config) }
        }
    }
    @Published var secretKey: String {
        didSet {
            let clean = secretKey.removingWhitespace
            if clean != secretKey { secretKey = clean; return }
            if secretKey != oldValue { Keychain.set(secretKey, .secret) }
        }
    }
    /// Encryption passphrase (spaces allowed, newlines stripped).
    @Published var passphrase: String {
        didSet {
            let clean = passphrase.filter { !$0.isNewline }
            if clean != passphrase { passphrase = clean; return }
            if passphrase != oldValue { Keychain.set(passphrase, .passphrase) }
        }
    }
    @Published var language = L10n.setting { didSet { L10n.setting = language } }
    @Published var history: [RunRecord]
    @Published var progress: BackupProgress?
    @Published var isRunning = false
    @Published var restoreResult: RestoreResult?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginError: String?

    private var task: Task<Void, Never>?
    private var timer: Timer?

    init() {
        var loaded = Store.loadConfig()
        loaded.destination = loaded.destination.sanitized
        Store.saveConfig(loaded)
        config = loaded
        history = Store.loadHistory()
        secretKey = Keychain.get(.secret).removingWhitespace
        passphrase = Keychain.get(.passphrase)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    var lastRun: RunRecord? { history.first }

    /// Next scheduled run: one interval after the last attempt (successful or not).
    var nextRun: Date? {
        guard let interval = config.frequency.interval else { return nil }
        guard let last = lastRun else { return Date() }
        return last.start.addingTimeInterval(interval)
    }

    private func tick() {
        guard !isRunning, config.isReady, let next = nextRun, next <= Date() else { return }
        startBackup()
    }

    private func report(_ update: BackupProgress) {
        guard isRunning else { return }
        progress = update
    }

    // MARK: Backup

    func startBackup() {
        guard !isRunning else { return }
        isRunning = true
        progress = BackupProgress(phase: .connecting)
        let config = config, secret = secretKey, passphrase = passphrase
        task = Task { [weak self] in
            let record = await BackupEngine.run(config: config, secret: secret, passphrase: passphrase) { update in
                Task { @MainActor in self?.report(update) }
            }
            self?.finish(record)
        }
    }

    func cancel() { task?.cancel() }

    private func finish(_ record: RunRecord) {
        isRunning = false
        progress = nil
        task = nil
        history.insert(record, at: 0)
        history = Array(history.prefix(100))
        Store.saveHistory(history)
        notify(record)
    }

    func clearHistory() {
        history = []
        Store.saveHistory(history)
    }

    // MARK: Restore

    func fetchSnapshots() async throws -> [RemoteSnapshot] {
        guard let client = S3Client(config.destination, secret: secretKey) else {
            throw S3Error(status: 0, code: "Configuración", message: t("Endpoint o bucket no válidos.", "Invalid endpoint or bucket."))
        }
        return try await RestoreEngine.snapshots(client, base: RestoreEngine.basePrefix(config))
    }

    func startRestore(_ snapshot: RemoteSnapshot, to destination: URL) {
        guard !isRunning else { return }
        isRunning = true
        restoreResult = nil
        progress = BackupProgress(phase: .restoring)
        let config = config, secret = secretKey, passphrase = passphrase
        task = Task { [weak self] in
            let result = await RestoreEngine.run(config: config, secret: secret, passphrase: passphrase,
                                                 snapshot: snapshot, destination: destination) { update in
                Task { @MainActor in self?.report(update) }
            }
            guard let self else { return }
            self.isRunning = false
            self.progress = nil
            self.task = nil
            self.restoreResult = result
        }
    }

    // MARK: Export / import configuration

    func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "drops3-config.json"
        panel.allowedContentTypes = [.json]
        panel.message = t("Se exporta la configuración sin la Secret Key ni la clave de cifrado.", "Settings are exported without the Secret Key or the encryption passphrase.")
        guard panel.runModal() == .OK, let url = panel.url, let data = ConfigExport.encode(config) else { return }
        do { try data.write(to: url, options: .atomic) } catch { alert(t("No se pudo exportar", "Couldn't export"), error.localizedDescription) }
    }

    func importConfig() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = t("Importar", "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let imported = ConfigExport.decode(data) else {
            alert(t("No se pudo importar", "Couldn't import"), t("El archivo no es una configuración exportada por DropS3.", "The file is not a settings file exported by DropS3."))
            return
        }
        let confirm = NSAlert()
        confirm.messageText = t("¿Reemplazar la configuración actual?", "Replace current settings?")
        confirm.informativeText = t("Se sustituirán las carpetas, exclusiones, destino y programación por los del archivo. Las claves guardadas no cambian.", "Folders, exclusions, destination and schedule will be replaced with those in the file. Saved keys are not changed.")
        confirm.addButton(withTitle: t("Reemplazar", "Replace"))
        confirm.addButton(withTitle: t("Cancelar", "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        config = imported

        var pending: [String] = []
        if secretKey.isEmpty { pending.append(t("la Secret Access Key", "the Secret Access Key")) }
        if imported.encrypt && passphrase.isEmpty { pending.append(t("la clave de cifrado", "the encryption passphrase")) }
        let missing = imported.folders.filter { !FileManager.default.fileExists(atPath: $0) }
        var text = pending.isEmpty ? "" : t("Falta escribir \(pending.joined(separator: " y ")) en Destino. ", "Still needed in Destination: \(pending.joined(separator: " and ")). ")
        if !missing.isEmpty { text += t("\(missing.count) de las carpetas configuradas no existen en este equipo.", "\(missing.count) of the configured folders don't exist on this Mac.") }
        alert(t("Configuración importada", "Settings imported"), text)
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Misc

    func testConnection() async -> (ok: Bool, message: String) {
        guard let client = S3Client(config.destination, secret: secretKey) else {
            return (false, t("Endpoint o bucket no válidos.", "Invalid endpoint or bucket."))
        }
        do {
            try await client.checkBucket()
            let count = try await BackupEngine.listSnapshots(client, base: RestoreEngine.basePrefix(config)).count
            return (true, t("Conexión correcta · \(count) \(count == 1 ? "copia" : "copias") en el destino", "Connected · \(count) \(count == 1 ? "backup" : "backups") at the destination"))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func notify(_ record: RunRecord) {
        guard Bundle.main.bundleIdentifier != nil, record.status == .failed || record.status == .warnings else { return }
        let content = UNMutableNotificationContent()
        content.title = record.status == .failed ? t("El respaldo falló", "Backup failed") : t("Respaldo con errores", "Backup finished with errors")
        content.body = record.message ?? t("\(record.issueCount) archivos no se pudieron copiar.", "\(record.issueCount) files could not be backed up.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
    }
}
