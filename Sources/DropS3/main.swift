import SwiftUI

// `DropS3 --backup-now` runs one backup headlessly with the saved configuration.
if CommandLine.arguments.contains("--backup-now") {
    Task {
        let record = await BackupEngine.run(config: Store.loadConfig(), secret: Keychain.get(.secret), passphrase: Keychain.get(.passphrase)) { _ in }
        Store.saveHistory([record] + Store.loadHistory())
        print(t("\(record.status.rawValue): \(record.files) archivos, \(formatBytes(record.bytes)), \(record.issueCount) errores, \(record.pruned) copias eliminadas", "\(record.status.rawValue): \(record.files) files, \(formatBytes(record.bytes)), \(record.issueCount) errors, \(record.pruned) backups deleted"))
        if let message = record.message { print(message) }
        for issue in record.issues { print("  \(issue.path): \(issue.message)") }
        exit(record.status == .ok ? 0 : 1)
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--test-connection") {
    // Read-only check of the saved destination.
    Task {
        let config = Store.loadConfig()
        guard let client = S3Client(config.destination, secret: Keychain.get(.secret)) else {
            print(t("Endpoint o bucket no válidos.", "Invalid endpoint or bucket.")); exit(1)
        }
        do {
            try await client.checkBucket()
            let trimmed = config.destination.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let snapshots = try await BackupEngine.listSnapshots(client, base: trimmed.isEmpty ? "" : trimmed + "/")
            print(t("Conexión correcta: \(snapshots.count) copias en el destino", "Connected: \(snapshots.count) backups at the destination"))
            exit(0)
        } catch {
            print("Error: \(error.localizedDescription)"); exit(1)
        }
    }
    dispatchMain()
} else if let index = CommandLine.arguments.firstIndex(of: "--restore"), CommandLine.arguments.count > index + 2 {
    // `DropS3 --restore <latest|snapshot> <folder>`
    let wanted = CommandLine.arguments[index + 1]
    let destination = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    Task {
        let config = Store.loadConfig()
        guard let client = S3Client(config.destination, secret: Keychain.get(.secret)) else {
            print(t("Endpoint o bucket no válidos.", "Invalid endpoint or bucket.")); exit(1)
        }
        do {
            let all = try await RestoreEngine.snapshots(client, base: RestoreEngine.basePrefix(config))
            guard let snapshot = wanted == "latest" ? all.first(where: \.complete) : all.first(where: { $0.name == wanted }) else {
                print(t("No se encontró la copia \(wanted).", "Backup \(wanted) not found.")); exit(1)
            }
            let result = await RestoreEngine.run(config: config, secret: Keychain.get(.secret), passphrase: Keychain.get(.passphrase),
                                                 snapshot: snapshot, destination: destination) { _ in }
            print(t("\(result.ok ? "ok" : "error"): \(snapshot.name)\(snapshot.encrypted ? " (cifrada)" : ""), \(result.files) archivos, \(formatBytes(result.bytes)), \(result.issueCount) errores", "\(result.ok ? "ok" : "error"): \(snapshot.name)\(snapshot.encrypted ? " (encrypted)" : ""), \(result.files) files, \(formatBytes(result.bytes)), \(result.issueCount) errors"))
            if let message = result.message { print(message) }
            for issue in result.issues { print("  \(issue.path): \(issue.message)") }
            exit(result.ok ? 0 : 1)
        } catch {
            print("Error: \(error.localizedDescription)"); exit(1)
        }
    }
    dispatchMain()
} else {
    DropS3App.main()
}

struct DropS3App: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("DropS3", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 820, height: 540)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .importExport) {
                Button(t("Exportar configuración…", "Export settings…")) { state.exportConfig() }
                Button(t("Importar configuración…", "Import settings…")) { state.importConfig() }.disabled(state.isRunning)
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(state)
        } label: {
            Image(systemName: state.isRunning ? "arrow.triangle.2.circlepath" : "externaldrive.badge.checkmark")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if state.isRunning {
            Text(t("Respaldando… \(Int((state.progress?.fraction ?? 0) * 100)) %", "Backing up… \(Int((state.progress?.fraction ?? 0) * 100)) %"))
            Button(t("Cancelar", "Cancel")) { state.cancel() }
        } else {
            if let last = state.lastRun {
                Text(t("Último: \(last.end.formatted(date: .abbreviated, time: .shortened)) · \(last.status.title)", "Last: \(last.end.formatted(date: .abbreviated, time: .shortened)) · \(last.status.title)"))
            } else {
                Text(t("Sin respaldos todavía", "No backups yet"))
            }
            Button(t("Respaldar ahora", "Back up now")) { state.startBackup() }.disabled(!state.config.isReady)
        }
        Divider()
        Button(t("Abrir DropS3", "Open DropS3")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(t("Salir", "Quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
