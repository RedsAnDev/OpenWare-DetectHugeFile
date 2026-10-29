import Foundation
import AppKit
import SwiftUI
import CryptoKit

struct DupFile: Identifiable { let id: String; let mtime: Int64 }

struct DupGroup: Identifiable {
    let id: String          // hash
    let size: UInt64
    var files: [DupFile]
    var wasted: UInt64 { size * UInt64(max(0, files.count - 1)) }
}

private func hashFile(_ path: String, limit: Int?) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    var h = SHA256()
    var remaining = limit ?? Int.max
    while remaining > 0 {
        let chunk = fh.readData(ofLength: min(1 << 20, remaining))
        if chunk.isEmpty { break }
        h.update(data: chunk)
        remaining -= chunk.count
    }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Stato condiviso fra thread di analisi e UI (annullamento + messaggio di avanzamento).
final class DupState: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancel = false
    private var _stage = ""
    var cancelled: Bool { get { lock.lock(); defer { lock.unlock() }; return _cancel } set { lock.lock(); _cancel = newValue; lock.unlock() } }
    var stage: String { get { lock.lock(); defer { lock.unlock() }; return _stage } set { lock.lock(); _stage = newValue; lock.unlock() } }
}

/// Duplicati reali: stessa dimensione → hash del primo MB → SHA-256 completo. Usabile da qualunque thread.
func computeDuplicates(_ all: [(String, UInt64, Int64)], state: DupState) -> [DupGroup] {
        func isCancelled() -> Bool { state.cancelled }
        func setStage(_ s: String) { state.stage = s }
        // 1) stessa dimensione
        var bySize: [UInt64: [(String, Int64)]] = [:]
        for (p, s, m) in all { bySize[s, default: []].append((p, m)) }
        let candidates = bySize.filter { $0.value.count > 1 }
        let total = candidates.values.reduce(0) { $0 + $1.count }

        // 2) hash parziale (primo MB), poi 3) hash completo solo dei sopravvissuti
        func refine(_ items: [(size: UInt64, path: String, mtime: Int64)], limit: Int?, label: String) -> [String: [(size: UInt64, path: String, mtime: Int64)]] {
            var result: [String: [(size: UInt64, path: String, mtime: Int64)]] = [:]
            let lock = NSLock()
            var done = 0
            DispatchQueue.concurrentPerform(iterations: items.count) { i in
                if isCancelled() { return }
                let it = items[i]
                if let h = hashFile(it.path, limit: limit) {
                    lock.lock()
                    result["\(it.size)-\(h)", default: []].append(it)
                    done += 1
                    if done % 20 == 0 { setStage("\(label): \(done)/\(items.count)") }
                    lock.unlock()
                }
            }
            return result
        }

        let flat = candidates.flatMap { (s, v) in v.map { (size: s, path: $0.0, mtime: $0.1) } }
        setStage("Confronto iniziale di \(total) file…")
        let partial = refine(flat, limit: 1 << 20, label: "Confronto iniziale")
        let survivors = partial.values.filter { $0.count > 1 }.flatMap { $0 }
        let full = refine(survivors, limit: nil, label: "Verifica completa")

        var groups: [DupGroup] = []
        for (key, v) in full where v.count > 1 {
            groups.append(DupGroup(id: key, size: v[0].size, files: v.map { DupFile(id: $0.path, mtime: $0.mtime) }.sorted { $0.mtime < $1.mtime }))
        }
        groups.sort { $0.wasted > $1.wasted }
        return groups
}

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var groups: [DupGroup] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var status = "Scegli una cartella e premi “Scansiona”."
    @Published var rootPath = NSHomeDirectory()
    @Published var minMB = 5
    @Published var selection: Set<String> = []
    @Published var busy = false

    private var scanner: Scanner?
    fileprivate var timer: Timer?
    private let state = DupState()

    var wasted: UInt64 { groups.reduce(0) { $0 + $1.wasted } }

    func chooseRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Scansiona"
        if p.runModal() == .OK, let u = p.url { rootPath = u.path; scan() }
    }

    func cancel() {
        state.cancelled = true
        scanner?.cancel(); timer?.invalidate(); scanning = false; status = "Annullato"
    }

    func scan() {
        scanner?.cancel(); timer?.invalidate()
        groups = []; selection = []
        scanning = true; progress = "Elenco dei file…"
        state.cancelled = false; state.stage = ""
        let home = NSHomeDirectory()
        let sc = Scanner(path: rootPath, extraSkip: [home + "/Library", home + "/.Trash"], bigFileThreshold: UInt64(minMB) << 20)
        scanner = sc
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self, weak sc] _ in
            guard let self else { return }
            if let sc, self.state.stage.isEmpty { let s = sc.stats; Task { @MainActor in self.progress = "Elenco dei file… \(s.files.formatted()) file · \(s.current)" } }
            else { let st = self.state.stage; Task { @MainActor in self.progress = st } }
        }
        sc.onFinish = { [weak self, weak sc] in
            guard let self, let sc, self.scanner === sc, !sc.cancelled else { return }
            sc.onFinish = nil
            var files: [Node] = []
            var stack = [sc.root]
            while let n = stack.popLast() {
                for c in n.children {
                    if c.isDir { if c.name != "node_modules" && c.name != ".git" { stack.append(c) } }
                    else { files.append(c) }
                }
            }
            let paths = files.map { ($0.path, $0.size, $0.mtime) }
            let st = self.state
            DispatchQueue.global(qos: .userInitiated).async { Self.analyze(paths, st, self) }
        }
        sc.start()
    }

    private nonisolated static func analyze(_ all: [(String, UInt64, Int64)], _ state: DupState, _ model: DuplicatesModel) {
        let groups = computeDuplicates(all, state: state)
        let cancelled = state.cancelled
        DispatchQueue.main.async {
            state.stage = ""
            model.timer?.invalidate()
            model.scanning = false
            if cancelled { return }
            model.groups = groups
            model.status = groups.isEmpty ? "Nessun duplicato trovato" : "\(groups.count) gruppi di duplicati · \(formatBytes(model.wasted)) recuperabili"
        }
    }

    // MARK: selezione automatica

    enum Keep { case oldest, newest, shortestPath }

    func autoSelect(_ keep: Keep) {
        var sel: Set<String> = []
        for g in groups {
            let ordered: [DupFile]
            switch keep {
            case .oldest: ordered = g.files.sorted { $0.mtime < $1.mtime }
            case .newest: ordered = g.files.sorted { $0.mtime > $1.mtime }
            case .shortestPath: ordered = g.files.sorted { $0.id.count < $1.id.count }
            }
            for f in ordered.dropFirst() { sel.insert(f.id) }
        }
        selection = sel
    }

    func exportTable() -> ExportTable {
        ExportTable(headers: ["Gruppo", "Byte", "Dimensione", "Copie", "Percorso", "Modificata"],
                    rows: groups.enumerated().flatMap { (i, g) in g.files.map { ["\(i + 1)", String(g.size), formatBytes(g.size), String(g.files.count), $0.id, exportDate($0.mtime)] } })
    }

    func trash() {
        let sizes = Dictionary(uniqueKeysWithValues: groups.flatMap { g in g.files.map { ($0.id, g.size) } })
        let sel = selection.filter { sizes[$0] != nil }.sorted()
        guard !sel.isEmpty, !busy else { return }
        // non cancellare mai tutte le copie di un gruppo
        let risky = groups.filter { g in g.files.allSatisfy { selection.contains($0.id) } }
        if !risky.isEmpty {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Almeno una copia per gruppo deve restare"
            a.informativeText = "In \(risky.count) gruppi hai selezionato tutte le copie (es. \(abbreviate(risky[0].files[0].id))). Deseleziona almeno una copia per gruppo."
            a.runModal()
            return
        }
        let total = sel.reduce(0) { $0 + (sizes[$1] ?? 0) }
        if dryRunReport(count: sel.count, bytes: total, detail: sel.prefix(10).map { "• " + abbreviate($0) }.joined(separator: "\n")) { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Spostare \(sel.count) copie nel Cestino?"
        a.informativeText = sel.prefix(8).map { "• \(abbreviate($0))" }.joined(separator: "\n") + (sel.count > 8 ? "\n… e altre \(sel.count - 8)" : "") +
            "\n\nSpazio recuperabile: \(formatBytes(total)). In ogni gruppo resta almeno una copia."
        a.addButton(withTitle: "Sposta nel Cestino")
        a.addButton(withTitle: "Annulla")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }

        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var done: Set<String> = [], fails = 0
            var log: [TrashEntry] = []
            for p in sel { do { try trashLogged(p, &log); done.insert(p) } catch { fails += 1 } }
            DispatchQueue.main.async { [self] in
                TrashLog.shared.record("Duplicati", log)
                for i in groups.indices { groups[i].files.removeAll { done.contains($0.id) } }
                groups.removeAll { $0.files.count < 2 }
                selection.subtract(done)
                busy = false
                status = "Nel Cestino: \(done.count) copie (\(formatBytes(done.reduce(0) { $0 + (sizes[$1] ?? 0) })))" + (fails > 0 ? " · \(fails) falliti" : "")
            }
        }
    }
}

private let dupDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM/yy HH:mm"; return f }()

struct DuplicatiView: View {
    @ObservedObject var dup: DuplicatesModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                List {
                    ForEach(dup.groups.prefix(500)) { g in
                        Section {
                            ForEach(g.files) { f in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: Binding(get: { dup.selection.contains(f.id) },
                                                             set: { if $0 { dup.selection.insert(f.id) } else { dup.selection.remove(f.id) } }))
                                        .labelsHidden().toggleStyle(.checkbox)
                                    Text(abbreviate(f.id)).lineLimit(1).truncationMode(.middle).help(f.id)
                                    Spacer()
                                    Text(f.mtime == 0 ? "—" : dupDate.string(from: Date(timeIntervalSince1970: TimeInterval(f.mtime))))
                                        .foregroundStyle(.secondary).font(.callout)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.id)]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless).help("Mostra nel Finder")
                                }
                            }
                        } header: {
                            HStack {
                                Text(URL(fileURLWithPath: g.files[0].id).lastPathComponent).fontWeight(.semibold)
                                Text("\(g.files.count) copie × \(formatBytes(g.size))").foregroundStyle(.secondary)
                                Spacer()
                                Text("spreco \(formatBytes(g.wasted))").foregroundStyle(g.wasted > 1 << 30 ? Color.red : Color.orange)
                            }
                        }
                    }
                    if dup.groups.count > 500 { Text("Mostrati i primi 500 gruppi su \(dup.groups.count) (per spreco).").foregroundStyle(.secondary) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                if dup.scanning {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Ricerca duplicati…").font(.headline)
                        Text(dup.progress).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).frame(maxWidth: 560)
                        Button("Annulla") { dup.cancel() }
                    }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else if dup.groups.isEmpty {
                    Text(dup.status).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 14) {
                if dup.selection.isEmpty { Text(dup.status) } else {
                    Text("\(dup.selection.count) copie selezionate").fontWeight(.medium)
                }
                Spacer()
                Text("Nota: i cloni APFS condividono lo spazio e qui risultano come duplicati.")
                Text("Radice: \(abbreviate(dup.rootPath))")
            }
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Scegli cartella…") { dup.chooseRoot() }
                    Divider()
                    VolumeMenuItems { dup.rootPath = $0; dup.scan() }
                } label: { Label("Cartella", systemImage: "folder") }
                Picker("Soglia", selection: $dup.minMB) {
                    Text("≥ 1 MB").tag(1); Text("≥ 5 MB").tag(5); Text("≥ 20 MB").tag(20); Text("≥ 100 MB").tag(100)
                }.help("Dimensione minima dei file da confrontare")
                Button { dup.scan() } label: { Label("Scansiona", systemImage: "magnifyingglass.circle") }.disabled(dup.scanning)
                Menu {
                    Button("Tieni la copia più vecchia") { dup.autoSelect(.oldest) }
                    Button("Tieni la copia più recente") { dup.autoSelect(.newest) }
                    Button("Tieni il percorso più corto") { dup.autoSelect(.shortestPath) }
                    Divider()
                    Button("Deseleziona tutto") { dup.selection = [] }
                } label: { Label("Auto-selezione", systemImage: "wand.and.stars") }
                Button(role: .destructive) { dup.trash() } label: { Label("Sposta nel Cestino", systemImage: "trash") }
                    .disabled(dup.selection.isEmpty || dup.busy)
                GlobalToolbarButtons()
            }
        }
    }
}
