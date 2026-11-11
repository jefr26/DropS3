import SwiftUI
import AppKit

extension RunStatus {
    var title: String {
        switch self {
        case .ok: t("Correcto", "OK")
        case .warnings: t("Con errores", "With errors")
        case .failed: t("Falló", "Failed")
        case .cancelled: t("Cancelado", "Cancelled")
        }
    }
    var icon: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warnings: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .ok: .green
        case .warnings: .orange
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case overview, folders, excludes, destination, schedule, restore, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: t("Resumen", "Overview")
        case .folders: t("Carpetas", "Folders")
        case .excludes: t("Exclusiones", "Exclusions")
        case .destination: t("Destino", "Destination")
        case .schedule: t("Programación", "Schedule")
        case .restore: t("Restaurar", "Restore")
        case .history: t("Historial", "History")
        }
    }
    var icon: String {
        switch self {
        case .overview: "circle.dashed"
        case .folders: "folder"
        case .excludes: "eye.slash"
        case .destination: "externaldrive.connected.to.line.below"
        case .schedule: "clock"
        case .restore: "arrow.counterclockwise"
        case .history: "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Stored private var pane: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) {
                Menu {
                    Button(t("Exportar configuración…", "Export settings…")) { state.exportConfig() }
                    Button(t("Importar configuración…", "Import settings…")) { state.importConfig() }.disabled(state.isRunning)
                    Divider()
                    Picker(t("Idioma", "Language"), selection: $state.language) {
                        Text(t("Automático (sistema)", "Automatic (system)")).tag(AppLanguage.system)
                        Text("Español").tag(AppLanguage.es)
                        Text("English").tag(AppLanguage.en)
                    }
                } label: {
                    Label(t("Configuración", "Settings"), systemImage: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        } detail: {
            Group {
                switch pane ?? .overview {
                case .overview: OverviewView(pane: $pane)
                case .folders: FoldersView()
                case .excludes: ExcludesView()
                case .destination: DestinationView()
                case .schedule: ScheduleView()
                case .restore: RestoreView()
                case .history: HistoryView()
                }
            }
            .navigationTitle((pane ?? .overview).title)
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var state: AppState
    @Binding var pane: Pane?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            if state.isRunning, let progress = state.progress {
                running(progress)
            } else {
                idle
            }
            Spacer()
            footer
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var idle: some View {
        let last = state.lastRun
        Image(systemName: last?.status.icon ?? "externaldrive")
            .font(.system(size: 56, weight: .light))
            .foregroundStyle(last?.status.color ?? .secondary)
            .symbolRenderingMode(.hierarchical)

        VStack(spacing: 6) {
            Text(headline(last)).font(.title2.weight(.semibold))
            if let last {
                Text(t("\(last.end.formatted(.relative(presentation: .named))) · \(last.files) archivos · \(formatBytes(last.bytes))", "\(last.end.formatted(.relative(presentation: .named))) · \(last.files) files · \(formatBytes(last.bytes))"))
                    .foregroundStyle(.secondary)
                if let message = last.message {
                    Text(message).foregroundStyle(last.status.color).multilineTextAlignment(.center)
                }
                if last.issueCount > 0 {
                    Button(t("Ver \(last.issueCount) \(last.issueCount == 1 ? "error" : "errores")", "View \(last.issueCount) \(last.issueCount == 1 ? "error" : "errors")")) { pane = .history }
                        .buttonStyle(.link)
                }
            } else {
                Text(t("Configura las carpetas y el destino para empezar.", "Set up folders and a destination to get started.")).foregroundStyle(.secondary)
            }
        }

        Button { state.startBackup() } label: {
            Text(t("Respaldar ahora", "Back up now")).padding(.horizontal, 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!state.config.isReady)
    }

    @ViewBuilder private func running(_ p: BackupProgress) -> some View {
        VStack(spacing: 14) {
            Text(phaseTitle(p.phase)).font(.title2.weight(.semibold))
            if p.phase == .uploading || p.phase == .restoring {
                ProgressView(value: p.fraction).frame(maxWidth: 360)
                Text(t("\(p.filesDone) de \(p.filesTotal) archivos · \(formatBytes(p.bytesDone)) de \(formatBytes(p.bytesTotal))", "\(p.filesDone) of \(p.filesTotal) files · \(formatBytes(p.bytesDone)) of \(formatBytes(p.bytesTotal))"))
                    .foregroundStyle(.secondary).monospacedDigit()
                Text(p.current).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
            } else {
                ProgressView().controlSize(.small)
            }
            Button(t("Cancelar", "Cancel")) { state.cancel() }.controlSize(.large)
        }
    }

    private var footer: some View {
        HStack(spacing: 28) {
            stat(t("Carpetas", "Folders"), "\(state.config.folders.count)")
            stat(t("Destino", "Destination"), state.config.destination.bucket.isEmpty ? "—" : state.config.destination.bucket)
            stat(t("Copias", "Copies"), "\(state.config.keepCopies)")
            stat(t("Próximo", "Next"), nextText)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.weight(.medium)).lineLimit(1)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
    }

    private var nextText: String {
        guard let next = state.nextRun else { return "Manual" }
        return next <= Date() ? t("Ahora", "Now") : next.formatted(date: .abbreviated, time: .shortened)
    }

    private func headline(_ last: RunRecord?) -> String {
        switch last?.status {
        case .ok: t("Respaldo correcto y verificado", "Backup completed and verified")
        case .warnings: t("Respaldo completado con errores", "Backup completed with errors")
        case .failed: t("El último respaldo falló", "The last backup failed")
        case .cancelled: t("El último respaldo se canceló", "The last backup was cancelled")
        case nil: t("Sin respaldos todavía", "No backups yet")
        }
    }

    private func phaseTitle(_ phase: BackupPhase) -> String {
        switch phase {
        case .connecting: t("Conectando…", "Connecting…")
        case .scanning: t("Analizando carpetas…", "Scanning folders…")
        case .uploading: t("Copiando y verificando…", "Uploading and verifying…")
        case .pruning: t("Eliminando copias antiguas…", "Removing old backups…")
        case .restoring: t("Restaurando y verificando…", "Restoring and verifying…")
        }
    }
}

// MARK: - Folders

struct FoldersView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.config.folders.isEmpty {
                ContentUnavailableView {
                    Label(t("Sin carpetas", "No folders"), systemImage: "folder.badge.plus")
                } description: {
                    Text(t("Elige las carpetas que quieres respaldar.", "Choose the folders you want to back up."))
                } actions: {
                    Button(t("Añadir carpeta…", "Add folder…"), action: add)
                }
            } else {
                List {
                    ForEach(state.config.folders, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button { state.config.folders.removeAll { $0 == path } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help(t("Quitar", "Remove"))
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem { Button(action: add) { Label(t("Añadir carpeta", "Add folder"), systemImage: "plus") } }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = t("Añadir", "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !state.config.folders.contains(url.path) {
            state.config.folders.append(url.path)
        }
    }
}

// MARK: - Excludes

struct ExcludesView: View {
    @EnvironmentObject var state: AppState
    @Stored private var draft = ""
    private let suggestions = ["node_modules", "vendor", ".git", ".DS_Store", "*.log", "dist", "build", ".cache", "DerivedData", "*.tmp"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField(t("Nombre, patrón (*.log) o ruta absoluta", "Name, pattern (*.log) or absolute path"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                Button(t("Añadir", "Add"), action: addDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .top], 16)

            let pending = suggestions.filter { !state.config.excludes.contains($0) }
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pending, id: \.self) { item in
                            Button { state.config.excludes.append(item) } label: {
                                Label(item, systemImage: "plus").font(.caption)
                            }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 10)
            }

            List {
                ForEach(state.config.excludes, id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.body.monospaced())
                        Spacer()
                        Button { state.config.excludes.removeAll { $0 == pattern } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help(t("Quitar", "Remove"))
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            .padding(.top, 8)

            Text(t("Los archivos y carpetas que coincidan se omiten en todas las carpetas respaldadas.", "Matching files and folders are skipped in every backed-up folder."))
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
    }

    private func addDraft() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if !state.config.excludes.contains(value) { state.config.excludes.append(value) }
        draft = ""
    }
}

// MARK: - Destination

struct DestinationView: View {
    @EnvironmentObject var state: AppState
    @Stored private var testing = false
    @Stored private var result: (ok: Bool, message: String)?

    var body: some View {
        Form {
            Section(t("Servidor S3 (Garage)", "S3 server (Garage)")) {
                TextField("Endpoint", text: $state.config.destination.endpoint, prompt: Text("http://localhost:3900"))
                TextField(t("Región", "Region"), text: $state.config.destination.region, prompt: Text("garage"))
            }
            Section(t("Ubicación", "Location")) {
                TextField("Bucket", text: $state.config.destination.bucket)
                TextField(t("Prefijo", "Prefix"), text: $state.config.destination.prefix, prompt: Text("backups"))
            }
            Section(t("Credenciales", "Credentials")) {
                TextField("Access Key ID", text: $state.config.destination.accessKey)
                SecureField("Secret Access Key", text: $state.secretKey)
            }
            Section {
                Toggle(t("Cifrar las copias", "Encrypt backups"), isOn: $state.config.encrypt)
                if state.config.encrypt {
                    SecureField(t("Clave de cifrado", "Encryption passphrase"), text: $state.passphrase)
                    if state.passphrase.isEmpty {
                        Label(t("Escribe una clave para poder cifrar.", "Enter a passphrase to enable encryption."), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text(t("Cifrado", "Encryption"))
            } footer: {
                Text(t("AES-256-GCM. La clave se guarda en el Llavero; si la pierdes, las copias cifradas no se pueden recuperar. El contenido se cifra, los nombres de archivo no.", "AES-256-GCM. The passphrase is stored in the Keychain; if you lose it, encrypted backups cannot be recovered. File contents are encrypted, file names are not."))
            }
            Section {
                HStack {
                    Button(t("Probar conexión", "Test connection")) {
                        testing = true
                        result = nil
                        Task {
                            result = await state.testConnection()
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                            .lineLimit(2)
                    }
                }
            } footer: {
                Text(t("La clave secreta se guarda en el Llavero de macOS.", "The secret key is stored in the macOS Keychain."))
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
    }
}

// MARK: - Schedule

struct ScheduleView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section(t("Frecuencia", "Frequency")) {
                Picker(t("Realizar copia", "Back up"), selection: $state.config.frequency) {
                    ForEach(Frequency.allCases) { Text($0.title).tag($0) }
                }
                if let next = state.nextRun {
                    LabeledContent(t("Próxima copia", "Next backup"), value: next <= Date() ? t("En breve", "Shortly") : next.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                Stepper(value: $state.config.keepCopies, in: 1...365) {
                    LabeledContent(t("Copias a mantener", "Backups to keep"), value: "\(state.config.keepCopies)")
                }
            } header: {
                Text(t("Retención", "Retention"))
            } footer: {
                Text(t("Tras cada copia correcta se eliminan las más antiguas que superen este número.", "After each successful backup, the oldest ones beyond this number are deleted."))
            }
            Section {
                Toggle(t("Abrir al iniciar sesión", "Open at login"), isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }))
                if let error = state.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text(t("Las copias programadas se ejecutan mientras DropS3 esté abierto; sigue activo en la barra de menús al cerrar la ventana.", "Scheduled backups run while DropS3 is open; it stays active in the menu bar when you close the window."))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Restore

struct RestoreView: View {
    @EnvironmentObject var state: AppState
    @Stored private var snapshots: [RemoteSnapshot] = []
    @Stored private var selection: RemoteSnapshot.ID?
    @Stored private var loading = false
    @Stored private var error: String?

    private var selected: RemoteSnapshot? { snapshots.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if state.isRunning, let p = state.progress, p.phase == .restoring {
                progressView(p)
            } else if loading && snapshots.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label(t("No se pudieron cargar las copias", "Couldn't load backups"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button(t("Reintentar", "Retry")) { Task { await reload() } }
                }
            } else if snapshots.isEmpty {
                ContentUnavailableView(t("Sin copias en el destino", "No backups at the destination"), systemImage: "externaldrive",
                                       description: Text(t("Cuando hagas un respaldo aparecerá aquí.", "Your backups will appear here.")))
            } else {
                List(snapshots, selection: $selection) { snapshot in
                    row(snapshot).tag(snapshot.id)
                }
                .listStyle(.inset)
            }

            if let result = state.restoreResult, !state.isRunning { resultView(result) }

            Divider()
            HStack {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("Restaurar en…", "Restore to…")) { chooseAndRestore() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isRunning || selected?.complete != true)
            }
            .padding(12)
        }
        .task { await reload() }
        .toolbar {
            ToolbarItem {
                Button { Task { await reload() } } label: { Label(t("Actualizar", "Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
    }

    private var hint: String {
        guard let selected else { return t("Elige una copia para restaurarla en la carpeta que quieras.", "Choose a backup to restore it to any folder.") }
        if !selected.complete { return t("Esta copia no terminó (sin manifiesto) y no se puede restaurar.", "This backup didn't finish (no manifest) and can't be restored.") }
        if selected.encrypted && state.passphrase.isEmpty { return t("Copia cifrada: escribe la clave en Destino → Cifrado.", "Encrypted backup: enter the passphrase in Destination → Encryption.") }
        return t("Los archivos existentes con el mismo nombre se reemplazan.", "Existing files with the same name are replaced.")
    }

    private func row(_ snapshot: RemoteSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot.complete ? "clock.arrow.circlepath" : "exclamationmark.triangle")
                .foregroundStyle(snapshot.complete ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.date?.formatted(date: .abbreviated, time: .standard) ?? snapshot.name)
                Text(snapshot.name).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if !snapshot.complete { Text(t("Incompleta", "Incomplete")).font(.caption).foregroundStyle(.orange) }
            if snapshot.encrypted {
                Label(t("Cifrada", "Encrypted"), systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func progressView(_ p: BackupProgress) -> some View {
        VStack(spacing: 14) {
            Text(t("Restaurando y verificando…", "Restoring and verifying…")).font(.title2.weight(.semibold))
            ProgressView(value: p.fraction).frame(maxWidth: 360)
            Text(t("\(p.filesDone) de \(p.filesTotal) archivos · \(formatBytes(p.bytesDone)) de \(formatBytes(p.bytesTotal))", "\(p.filesDone) of \(p.filesTotal) files · \(formatBytes(p.bytesDone)) of \(formatBytes(p.bytesTotal))"))
                .foregroundStyle(.secondary).monospacedDigit()
            Text(p.current).font(.caption).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
            Button(t("Cancelar", "Cancel")) { state.cancel() }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(_ result: RestoreResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Label(summary(result), systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : (result.files > 0 ? .orange : .red))
                Spacer()
                if result.files > 0 {
                    Button(t("Mostrar en Finder", "Show in Finder")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: result.destination)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.horizontal, 12).padding(.top, 6)
            if !result.issues.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.issues) { issue in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(issue.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(issue.message).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 110)
            }
        }
        .padding(.bottom, 6)
    }

    private func summary(_ r: RestoreResult) -> String {
        if let message = r.message, r.files == 0 { return message }
        var text = t("\(r.files) archivos restaurados y verificados (\(formatBytes(r.bytes)))", "\(r.files) files restored and verified (\(formatBytes(r.bytes)))")
        if r.issueCount > 0 { text += t(" · \(r.issueCount) con error", " · \(r.issueCount) failed") }
        if let message = r.message { text += " · \(message)" }
        return text
    }

    private func reload() async {
        loading = true
        error = nil
        do {
            snapshots = try await state.fetchSnapshots()
            if selected == nil { selection = snapshots.first(where: \.complete)?.id }
        } catch {
            snapshots = []
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func chooseAndRestore() {
        guard let snapshot = selected else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = t("Restaurar aquí", "Restore here")
        panel.message = t("Elige la carpeta donde restaurar la copia", "Choose the folder to restore the backup into")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.startRestore(snapshot, to: url)
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.history.isEmpty {
                ContentUnavailableView(t("Sin historial", "No history"), systemImage: "list.bullet.rectangle",
                                       description: Text(t("Aquí aparecerá el resultado de cada copia.", "The result of each backup will appear here.")))
            } else {
                List(state.history) { record in
                    if record.issues.isEmpty {
                        row(record)
                    } else {
                        DisclosureGroup {
                            ForEach(record.issues) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Text(issue.message).font(.caption).foregroundStyle(.red)
                                }
                                .textSelection(.enabled)
                                .padding(.vertical, 2)
                            }
                            if record.issueCount > record.issues.count {
                                Text(t("… y \(record.issueCount - record.issues.count) más", "… and \(record.issueCount - record.issues.count) more"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } label: { row(record) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { state.clearHistory() } label: { Label(t("Borrar historial", "Clear history"), systemImage: "trash") }
                    .disabled(state.history.isEmpty)
            }
        }
    }

    private func row(_ r: RunRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.status.icon).foregroundStyle(r.status.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.start.formatted(date: .abbreviated, time: .shortened))
                Text(detail(r)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(r.status.title).font(.caption).foregroundStyle(r.status.color)
        }
        .padding(.vertical, 3)
    }

    private func detail(_ r: RunRecord) -> String {
        var parts = [t("\(r.files) archivos", "\(r.files) files"), formatBytes(r.bytes),
                     Duration.seconds(r.end.timeIntervalSince(r.start)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))]
        if r.issueCount > 0 { parts.append(t("\(r.issueCount) errores", "\(r.issueCount) errors")) }
        if r.pruned > 0 { parts.append(t("\(r.pruned) copias antiguas eliminadas", "\(r.pruned) old backups deleted")) }
        if let message = r.message { parts.append(message) }
        return parts.joined(separator: " · ")
    }
}

/// With only the Command Line Tools installed (no Xcode) the `@State` macro plugin is missing,
/// so views use the underlying property wrapper type through this alias.
typealias Stored = SwiftUI.State
