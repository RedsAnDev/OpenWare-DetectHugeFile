// DetectHugeFile — mostra dove se ne va lo spazio su disco del Mac.
// Copyright (C) 2026 Andrea Rossi
//
// Questo programma è software libero: puoi ridistribuirlo e/o modificarlo
// secondo i termini della GNU General Public License, versione 3 o (a tua
// scelta) successiva, pubblicata dalla Free Software Foundation.
//
// Questo programma è distribuito nella speranza che sia utile, ma SENZA
// ALCUNA GARANZIA; senza neppure la garanzia implicita di COMMERCIABILITÀ
// o IDONEITÀ PER UNO SCOPO PARTICOLARE. Vedi la GNU General Public License
// per maggiori dettagli: <https://www.gnu.org/licenses/>.

import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var root: Node?
    @Published var scanning = false
    @Published var progress = ""
    @Published var status = ""
    @Published var selection: [Node] = []
    @Published var reloadToken = 0
    @Published var freeSpace: UInt64 = 0
    @Published var fdaMissing = false

    @Published var flatToggle = false { didSet { refresh() } }
    @Published var searchText = "" { didSet { scheduleRefresh() } }
    @Published var showFiles = true { didSet { refresh() } }
    @Published var minSizeMB = 0 { didSet { refresh() } }

    var onScanComplete: ((Node) -> Void)?
    let config = ViewConfig()
    private(set) var flatItems: [Node] = []
    private var scanner: Scanner?
    private var timer: Timer?
    private var searchWork: DispatchWorkItem?

    var isFlat: Bool { flatToggle || !searchText.isEmpty }

    init() {
        updateFreeSpace()
        fdaMissing = !Self.hasFullDiskAccess()
        onScanComplete = { HistoryModel.shared.save(root: $0) }
        scan(path: NSHomeDirectory())
    }

    func setSort(_ key: SortKey, ascending: Bool) {
        config.key = key; config.ascending = ascending
        refresh()
    }

    private func scheduleRefresh() {
        searchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func refresh() {
        config.showFiles = showFiles
        config.generation += 1
        flatItems = []
        if isFlat, let root {
            let q = searchText.lowercased()
            let minB = UInt64(minSizeMB) << 20
            var out: [Node] = []
            var stack = [root]
            while let n = stack.popLast() {
                for c in n.children {
                    if c.isDir { stack.append(c) }
                    if !c.isDir && !showFiles { continue }
                    if c.size < minB { continue }
                    if !q.isEmpty && !c.path.lowercased().contains(q) { continue }
                    out.append(c)
                }
            }
            if root.size >= minB && (q.isEmpty || root.path.lowercased().contains(q)) { out.append(root) }
            out.sort(by: config.less)
            flatItems = out
        }
        reloadToken += 1
    }

    // MARK: scansione

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Scansiona"
        if p.runModal() == .OK, let url = p.url { scan(path: url.path) }
    }

    func exportTable() -> ExportTable {
        var dirs: [Node] = []
        var stack: [Node] = root.map { [$0] } ?? []
        while let n = stack.popLast() {
            if n.size >= 10 << 20 { dirs.append(n) }
            stack.append(contentsOf: n.children.filter { $0.isDir })
        }
        return ExportTable(headers: ["Percorso", "Byte", "Dimensione", "File", "Modificata", "Creata"],
                           rows: dirs.sorted { $0.size > $1.size }.map { [$0.path, String($0.size), formatBytes($0.size), String($0.files), exportDate($0.mtime), exportDate($0.btime)] })
    }

    func rescan() { if let r = root { scan(path: r.path) } }

    func scan(path: String) {
        scanner?.cancel()
        timer?.invalidate()
        let sc = Scanner(path: path)
        scanner = sc
        scanning = true
        selection = []
        status = ""
        progress = "Avvio…"
        let t0 = Date()
        sc.onFinish = { [weak self, weak sc] in
            guard let self, let sc, self.scanner === sc else { return }
            self.timer?.invalidate()
            self.scanning = false
            if sc.cancelled { return }
            self.root = sc.root
            self.onScanComplete?(sc.root)
            self.refresh()
            self.updateFreeSpace()
            let dt = Date().timeIntervalSince(t0)
            self.status = String(format: "Scansione completata in %.1f s · %@ in %d file", dt, formatBytes(sc.root.size), sc.root.files)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak sc] _ in
            guard let self, let sc else { return }
            let s = sc.stats
            Task { @MainActor in
                self.progress = "\(s.files.formatted()) file · \(s.dirs.formatted()) cartelle · \(formatBytes(s.bytes))   \(s.current)"
            }
        }
        sc.start()
    }

    func cancelScan() {
        scanner?.cancel()
        timer?.invalidate()
        scanning = false
        status = "Scansione annullata"
    }

    static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func updateFreeSpace() {
        if let v = try? URL(fileURLWithPath: root?.path ?? "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let c = v.volumeAvailableCapacityForImportantUsage { freeSpace = UInt64(max(0, c)) }
    }

    // MARK: azioni sui nodi

    func reveal(_ nodes: [Node]) {
        NSWorkspace.shared.activateFileViewerSelecting(nodes.map { URL(fileURLWithPath: $0.path) })
    }

    func copyPath(_ nodes: [Node]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nodes.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private static let protectedPaths: Set<String> = [
        "/", "/System", "/Users", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var",
        "/private", "/Volumes", "/opt", "/cores", NSHomeDirectory(), NSHomeDirectory() + "/Library",
        NSHomeDirectory() + "/Desktop", NSHomeDirectory() + "/Documents", NSHomeDirectory() + "/Downloads",
        NSHomeDirectory() + "/Pictures", NSHomeDirectory() + "/Movies", NSHomeDirectory() + "/Music",
    ]

    func trashSelection() {
        // scarta nodi il cui antenato è già selezionato
        let sel = selection.filter { n in !selection.contains { $0 !== n && n.isDescendant(of: $0) } }
        guard !sel.isEmpty else { return }
        let blocked = sel.filter { $0.parent == nil || isProtectedPath($0.path) }
        if !blocked.isEmpty {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Elemento protetto"
            a.informativeText = "Per sicurezza non posso spostare nel Cestino:\n" + blocked.map(\.path).joined(separator: "\n")
            a.runModal()
            return
        }
        let total = sel.reduce(0) { $0 + $1.size }
        if dryRunReport(count: sel.count, bytes: total, detail: sel.prefix(10).map { "• \($0.path)" }.joined(separator: "\n")) { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = sel.count == 1 ? "Spostare “\(sel[0].name)” nel Cestino?" : "Spostare \(sel.count) elementi nel Cestino?"
        let list = sel.prefix(8).map { "• \($0.path) — \(formatBytes($0.size))" }.joined(separator: "\n")
        a.informativeText = "\(list)\(sel.count > 8 ? "\n… e altri \(sel.count - 8)" : "")\n\nTotale: \(formatBytes(total)). Potrai recuperarli dal Cestino; lo spazio verrà liberato solo svuotandolo."
        a.addButton(withTitle: "Sposta nel Cestino")
        a.addButton(withTitle: "Annulla")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }

        status = "Spostamento nel Cestino…"
        let items = sel
        DispatchQueue.global(qos: .userInitiated).async {
            var ok: [Node] = [], failed: [(Node, String)] = []
            var log: [TrashEntry] = []
            for n in items {
                do { try trashLogged(n.path, &log); ok.append(n) }
                catch { failed.append((n, error.localizedDescription)) }
            }
            DispatchQueue.main.async { [self] in
                TrashLog.shared.record("Lista", log)
                let freed = ok.reduce(0) { $0 + $1.size }
                ok.forEach { $0.detach() }
                selection = []
                refresh()
                updateFreeSpace()
                status = "Nel Cestino: \(ok.count) elementi (\(formatBytes(freed)))" + (failed.isEmpty ? "" : " · \(failed.count) falliti")
                if !failed.isEmpty {
                    let e = NSAlert()
                    e.messageText = "Alcuni elementi non sono stati spostati"
                    e.informativeText = failed.prefix(6).map { "\($0.0.name): \($0.1)" }.joined(separator: "\n")
                    e.runModal()
                }
            }
        }
    }

    func emptyTrash() {
        confirmAndEmptyTrash { [self] ok in
            updateFreeSpace()
            status = ok ? "Cestino svuotato" : "Impossibile svuotare il Cestino (consenti l'automazione di Finder)"
        }
    }
}

/// Chiede conferma e svuota il Cestino tramite Finder. `done(true)` se riuscito.
@MainActor
func confirmAndEmptyTrash(_ done: @escaping @MainActor (Bool) -> Void) {
    let a = NSAlert()
    a.alertStyle = .critical
    a.messageText = "Svuotare il Cestino?"
    a.informativeText = "I file nel Cestino verranno eliminati definitivamente."
    a.addButton(withTitle: "Svuota Cestino")
    a.addButton(withTitle: "Annulla")
    a.buttons[0].hasDestructiveAction = true
    guard a.runModal() == .alertFirstButtonReturn else { return }
    DispatchQueue.global(qos: .userInitiated).async {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty the trash")?.executeAndReturnError(&err)
        DispatchQueue.main.async { done(err == nil) }
    }
}
