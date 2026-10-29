import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Impostazioni

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var dryRun: Bool { didSet { UserDefaults.standard.set(dryRun, forKey: "dryRun") } }
    @Published var reminder: Bool
    @Published var toast = ""
    /// Impostato da ContentView: restituisce (nome file, tabella) della tab corrente.
    var exportProvider: (() -> (String, ExportTable))?

    init() {
        dryRun = UserDefaults.standard.bool(forKey: "dryRun")
        reminder = FileManager.default.fileExists(atPath: Reminder.plistPath)
    }

    func showToast(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in if self?.toast == m { self?.toast = "" } }
    }

    func restoreLast() {
        showToast(TrashLog.shared.restoreLast() + " — riscansiona per aggiornare le liste")
        DiskMonitor.shared.update()
    }

    func export(markdown: Bool) {
        guard let (name, table) = exportProvider?() else { return }
        saveExport(table, name: "DetectHugeFile-" + name, markdown: markdown)
    }

    func setReminder(_ on: Bool) {
        if on { Reminder.install() } else { Reminder.uninstall() }
        reminder = FileManager.default.fileExists(atPath: Reminder.plistPath)
    }
}

/// In modalità "a secco" le azioni distruttive mostrano solo cosa succederebbe. Ritorna true se ha gestito la richiesta.
@MainActor
func dryRunReport(count: Int, bytes: UInt64, detail: String) -> Bool {
    guard AppSettings.shared.dryRun else { return false }
    let a = NSAlert()
    a.messageText = "Simulazione — nessun file è stato toccato"
    a.informativeText = "Verrebbero rimossi \(count) elementi liberando circa \(formatBytes(bytes)).\n\n\(detail)\n\nDisattiva “Modalità a secco” dal menu ⋯ per eseguire davvero."
    a.runModal()
    return true
}

// MARK: - Promemoria mensile (LaunchAgent)

enum Reminder {
    static let label = "dev.rossiandrea.DetectHugeFile.check"
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    static func install() {
        guard let exe = Bundle.main.executablePath else { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(exe)</string><string>--check</string></array>
        <key>StartCalendarInterval</key><dict><key>Day</key><integer>1</integer><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
        <key>RunAtLoad</key><false/>
        </dict></plist>
        """
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents", withIntermediateDirectories: true)
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        _ = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
    }

    static func uninstall() {
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// Eseguito da `--check`: scansiona e notifica se ci sono molti artefatti vecchi.
    static func runCheck(minGB: Double, notify: Bool) {
        let home = NSHomeDirectory()
        let sc = Scanner(path: home, extraSkip: [home + "/Library", home + "/.Trash"])
        sc.onFinish = {
            let cutoff = Int64(Date().timeIntervalSince1970) - 90 * 86400
            let old = findArtifacts(root: sc.root).filter { $0.mtime < cutoff }
            let bytes = old.reduce(0) { $0 + $1.size }
            let msg = "Hai \(formatBytes(bytes)) di artefatti non toccati da 90 giorni (\(old.count) cartelle). Apri DetectHugeFile → Artefatti."
            print(msg)
            if notify && Double(bytes) >= minGB * 1_000_000_000 {
                _ = shell("/usr/bin/osascript", ["-e", "display notification \"\(msg)\" with title \"DetectHugeFile\""])
            }
            exit(0)
        }
        sc.start()
        dispatchMain()
    }
}

@discardableResult
func shell(_ exe: String, _ args: [String], timeout: TimeInterval = 0) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/podman/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    if timeout > 0 {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Cestino con annulla

struct TrashEntry: Codable { let original: String; let trashed: String }
struct TrashBatch: Codable, Identifiable { let id: UUID; let date: Date; let label: String; var entries: [TrashEntry] }

/// Sposta nel Cestino registrando dove è finito l'elemento (serve per il ripristino).
func trashLogged(_ path: String, _ log: inout [TrashEntry]) throws {
    var out: NSURL?
    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
    if let u = out as URL? { log.append(TrashEntry(original: path, trashed: u.path)) }
}

/// Registro del Cestino su file, condiviso tra app grafica e server MCP (processi diversi): ogni operazione rilegge il file.
enum TrashLogStore {
    private static let lock = NSLock()

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DetectHugeFile")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trashlog.json")
    }

    private static func readRaw() -> [TrashBatch] {
        guard let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode([TrashBatch].self, from: d) else { return [] }
        return b.filter { batch in batch.entries.contains { FileManager.default.fileExists(atPath: $0.trashed) } }
    }

    private static func write(_ b: [TrashBatch]) {
        if let d = try? JSONEncoder().encode(b) { try? d.write(to: url, options: .atomic) }
    }

    static func load() -> [TrashBatch] { lock.lock(); defer { lock.unlock() }; return readRaw() }

    static func append(_ label: String, _ entries: [TrashEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var b = readRaw()
        b.append(TrashBatch(id: UUID(), date: Date(), label: label, entries: entries))
        if b.count > 20 { b.removeFirst(b.count - 20) }
        write(b)
    }

    static func restoreLast() -> String {
        lock.lock(); defer { lock.unlock() }
        var batches = readRaw()
        guard let b = batches.last else { return "Niente da ripristinare" }
        let fm = FileManager.default
        var ok = 0, gone = 0, busy = 0
        for e in b.entries {
            guard fm.fileExists(atPath: e.trashed) else { gone += 1; continue }
            guard !fm.fileExists(atPath: e.original) else { busy += 1; continue }
            do {
                try fm.createDirectory(atPath: (e.original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: e.trashed, toPath: e.original)
                ok += 1
            } catch { busy += 1 }
        }
        batches.removeLast()
        write(batches)
        var m = "Ripristinati \(ok) elementi (\(b.label))"
        if gone > 0 { m += " · \(gone) non più nel Cestino" }
        if busy > 0 { m += " · \(busy) non ripristinabili (percorso già occupato)" }
        return m
    }
}

@MainActor
final class TrashLog: ObservableObject {
    static let shared = TrashLog()
    @Published private(set) var batches: [TrashBatch] = []

    init() {
        batches = TrashLogStore.load()
        // il server MCP può aver aggiunto lotti mentre l'app era in background
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() { batches = TrashLogStore.load() }
    func record(_ label: String, _ entries: [TrashEntry]) { TrashLogStore.append(label, entries); reload() }
    var lastLabel: String? { batches.last.map { "\($0.label) (\($0.entries.count) elementi)" } }
    func restoreLast() -> String { let m = TrashLogStore.restoreLast(); reload(); return m }
}

/// Percorsi che nessuna azione (GUI o MCP) può spostare nel Cestino: sistema, cartelle utente di primo livello,
/// radici dei volumi e cartelle con credenziali.
func isProtectedPath(_ path: String) -> Bool {
    let h = NSHomeDirectory()
    func check(_ raw: String) -> Bool {
        let p = (raw as NSString).standardizingPath
        let exact: Set<String> = ["/", "/System", "/Users", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var", "/private",
                                  "/Volumes", "/opt", "/cores", h, h + "/Library", h + "/Desktop", h + "/Documents", h + "/Downloads",
                                  h + "/Pictures", h + "/Movies", h + "/Music", h + "/Applications"]
        if exact.contains(p) { return true }
        let comps = p.split(separator: "/")
        if comps.count == 2 && comps[0] == "Volumes" { return true }
        let prefixes = ["/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db", "/Library/Apple",
                        h + "/.ssh", h + "/.gnupg", h + "/.aws", h + "/Library/Keychains"]
        return prefixes.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
    return check(path) || check(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
}

// MARK: - Misuratore di dimensioni (coda con concorrenza limitata)

@MainActor
final class SizeMeasurer {
    private var queue: [(String, (UInt64, Bool) -> Void)] = []
    private var running = 0
    var limit = 3
    var onIdle: (() -> Void)?

    func add(_ path: String, _ cb: @escaping (UInt64, Bool) -> Void) { queue.append((path, cb)); pump() }
    func cancel() { queue = [] }
    var isIdle: Bool { running == 0 && queue.isEmpty }

    private func pump() {
        while running < limit, !queue.isEmpty {
            let (p, cb) = queue.removeFirst()
            running += 1
            let sc = Scanner(path: p)
            sc.onFinish = { [self] in
                running -= 1
                cb(sc.root.size, sc.root.denied && sc.root.size == 0)
                sc.onFinish = nil
                pump()
                if isIdle { onIdle?() }
            }
            sc.start()
        }
    }
}

// MARK: - Esportazione

struct ExportTable {
    var headers: [String]
    var rows: [[String]]

    var csv: String {
        func q(_ s: String) -> String { s.contains(where: { ",\"\n;".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        return ([headers] + rows).map { $0.map(q).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    var markdown: String {
        func e(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var l = ["| " + headers.map(e).joined(separator: " | ") + " |", "|" + headers.map { _ in " --- " }.joined(separator: "|") + "|"]
        l += rows.map { "| " + $0.map(e).joined(separator: " | ") + " |" }
        return l.joined(separator: "\n") + "\n"
    }
}

@MainActor
func saveExport(_ t: ExportTable, name: String, markdown: Bool) {
    let p = NSSavePanel()
    p.nameFieldStringValue = name + (markdown ? ".md" : ".csv")
    p.allowedContentTypes = [markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .commaSeparatedText]
    guard p.runModal() == .OK, let u = p.url else { return }
    try? (markdown ? t.markdown : t.csv).write(to: u, atomically: true, encoding: .utf8)
}

private let exportDateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
func exportDate(_ t: Int64) -> String { t == 0 ? "" : exportDateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }

// MARK: - Volumi e spazio libero

struct VolumeInfo: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let total: UInt64
    let free: UInt64
    let isInternal: Bool
    let ejectable: Bool
    let format: String
}

func currentVolumes() -> [VolumeInfo] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                  .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                  .volumeIsRemovableKey, .volumeLocalizedFormatDescriptionKey]
    var out: [VolumeInfo] = []
    for u in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
        let total = UInt64(max(0, v.volumeTotalCapacity ?? 0))
        if total == 0 { continue }
        let freeB = UInt64(max(0, Int(v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0))))
        let internalVol = (v.volumeIsInternal ?? true) && !(v.volumeIsEjectable ?? false) && !(v.volumeIsRemovable ?? false)
        out.append(VolumeInfo(name: v.volumeName ?? u.lastPathComponent, path: u.path, total: total, free: freeB, isInternal: internalVol,
                              ejectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || !(v.volumeIsInternal ?? true),
                              format: v.volumeLocalizedFormatDescription ?? ""))
    }
    return out.sorted { ($0.isInternal ? 0 : 1, $0.name) < ($1.isInternal ? 0 : 1, $1.name) }
}

@MainActor
final class DiskMonitor: ObservableObject {
    static let shared = DiskMonitor()
    @Published var free: UInt64 = 0
    @Published var volumes: [VolumeInfo] = []
    private var timer: Timer?

    var external: [VolumeInfo] { volumes.filter { !$0.isInternal } }

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.update() } }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.update() } }
        }
    }

    func update() {
        volumes = currentVolumes()
        free = volumes.first { $0.path == "/" }?.free ?? 0
    }

    func eject(_ v: VolumeInfo) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: v.path)) }
        catch {
            let a = NSAlert(); a.messageText = "Impossibile espellere “\(v.name)”"; a.informativeText = error.localizedDescription; a.runModal()
        }
        update()
    }
}

/// Voci di menu "scansiona questo disco": interni ed esterni (USB, SD, dischi di rete montati).
struct VolumeMenuItems: View {
    @ObservedObject private var disk = DiskMonitor.shared
    let pick: (String) -> Void
    var body: some View {
        ForEach(disk.volumes) { v in
            Button { pick(v.path) } label: {
                Label("\(v.name) — \(formatBytes(v.free)) liberi di \(formatBytes(v.total))", systemImage: v.isInternal ? "internaldrive" : "externaldrive")
            }
        }
    }
}

/// Pulsanti comuni a tutte le tab: sempre in fondo al gruppo, quindi allineati all'estrema destra.
struct GlobalToolbarButtons: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var trashLog = TrashLog.shared
    var body: some View {
        Button { settings.restoreLast() } label: { Label("Ripristina", systemImage: "arrow.uturn.backward") }
            .disabled(trashLog.batches.isEmpty)
            .help(trashLog.lastLabel.map { "Ripristina l'ultima pulizia: \($0)" } ?? "Nessuna pulizia da ripristinare")
        Menu {
            Toggle("Modalità a secco (nessuna modifica)", isOn: $settings.dryRun)
            Toggle("Promemoria mensile artefatti vecchi", isOn: Binding(get: { settings.reminder }, set: { settings.setReminder($0) }))
            Divider()
            Button("Esporta CSV…") { settings.export(markdown: false) }
            Button("Esporta Markdown…") { settings.export(markdown: true) }
            Divider()
            Button("Accesso completo al disco…") { AppModel.openFullDiskAccessSettings() }
        } label: { Label("Altro", systemImage: settings.dryRun ? "eye.trianglebadge.exclamationmark" : "ellipsis.circle") }
    }
}
