import Foundation
import AppKit
import SwiftUI

enum Eco: String, CaseIterable, Identifiable {
    case node = "Node", bun = "Bun", hono = "Hono", rust = "Rust", flutter = "Flutter"
    case python = "Python", jvm = "Java/Gradle", swift = "Swift/Pods", go = "Go", other = "Altri", runtimes = "Versioni"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .node: return .green
        case .bun: return .yellow
        case .hono: return .orange
        case .rust: return .brown
        case .flutter: return .blue
        case .python: return .teal
        case .jvm: return .pink
        case .swift: return .mint
        case .go: return .cyan
        case .other: return .gray
        case .runtimes: return .purple
        }
    }
    var regen: String {
        switch self {
        case .node: return "npm install"
        case .bun: return "bun install"
        case .hono: return "npm/bun install"
        case .rust: return "cargo build"
        case .flutter: return "flutter pub get"
        case .python: return "pip/uv install"
        case .jvm: return "gradle/mvn build"
        case .swift: return "swift build / pod install"
        case .go: return "go mod vendor"
        case .other: return "composer/mix/dotnet"
        case .runtimes: return "reinstalla versione"
        }
    }
}

struct Artifact: Identifiable {
    let id: String          // percorso
    let eco: Eco
    let name: String
    let project: String
    var size: UInt64
    let mtime: Int64
    let global: Bool
    var locked = false      // versione attiva: non cancellabile
    var ecoName: String { eco.rawValue }
    var mtimeSort: Int64 { mtime }
}

private let nodeNames: Set<String> = ["node_modules", ".next", ".nuxt", ".svelte-kit", ".output", ".turbo",
                                      ".parcel-cache", ".angular", "dist", "build", ".vercel", ".wrangler"]
private let pyCacheNames: Set<String> = [".venv", "venv", ".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache"]
private let candidateNames: Set<String> = nodeNames.union(pyCacheNames)
    .union(["target", ".dart_tool", "Pods", ".gradle", ".build", "vendor", "_build", "deps", "bin", "obj"])
/// Cartelle di strumenti nella radice: non sono progetti, evitano falsi positivi.
private let toolHomes: Set<String> = [".nvm", ".pyenv", ".rustup", ".cargo", ".bun", ".npm", ".pub-cache", ".gradle", ".m2",
                                      ".cache", ".ollama", ".docker", ".volta", ".fnm", ".local", ".config", ".Trash"]

/// Cerca nell'albero scansionato le cartelle-artefatto dei vari ecosistemi.
/// Un nome da solo non basta: si verifica il manifest del progetto (package.json, Cargo.toml, pubspec.yaml, ...).
func findArtifacts(root: Node, minSize: UInt64 = 1 << 20) -> [Artifact] {
    let fm = FileManager.default
    var ecoCache: [String: Eco] = [:]
    func has(_ dir: String, _ f: String) -> Bool { fm.fileExists(atPath: dir + "/" + f) }
    func hasAny(_ dir: String, _ fs: [String]) -> Bool { fs.contains { has(dir, $0) } }

    func nodeEco(_ dir: String) -> Eco {
        if let e = ecoCache[dir] { return e }
        var e = Eco.node
        if let h = FileHandle(forReadingAtPath: dir + "/package.json") {
            let d = h.readData(ofLength: 65536); h.closeFile()
            if let s = String(data: d, encoding: .utf8), s.contains("\"hono\"") { e = .hono }
        }
        if e == .node, hasAny(dir, ["bun.lockb", "bun.lock", "bunfig.toml"]) { e = .bun }
        ecoCache[dir] = e
        return e
    }

    func flutterRoot(_ c: Node, _ parent: Node, _ pp: String) -> String? {
        switch c.name {
        case ".dart_tool": return has(pp, "pubspec.yaml") ? pp : nil
        case "build":
            if has(pp, "pubspec.yaml") { return pp }
            guard let gp = parent.parent else { return nil }
            if parent.name == "android", has(gp.path, "pubspec.yaml") { return gp.path }
            if parent.name == "app", gp.name == "android", let ggp = gp.parent, has(ggp.path, "pubspec.yaml") { return ggp.path }
            return nil
        case "Pods":
            if ["ios", "macos"].contains(parent.name), let gp = parent.parent, has(gp.path, "pubspec.yaml") { return gp.path }
            return nil
        case ".gradle":
            if parent.name == "android", let gp = parent.parent, has(gp.path, "pubspec.yaml") { return gp.path }
            return nil
        default: return nil
        }
    }

    func match(_ c: Node) -> (Eco, String)? {
        guard let parent = c.parent else { return nil }
        let pp = parent.path
        if let fr = flutterRoot(c, parent, pp) { return (.flutter, fr) }
        let hasPkg = has(pp, "package.json")
        let pyProject = hasAny(pp, ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "tox.ini", "Pipfile"])
        switch c.name {
        case "target":
            if has(pp, "Cargo.toml") { return (.rust, pp) }
            if has(pp, "pom.xml") { return (.jvm, pp) }
        case "node_modules": if hasPkg { return (nodeEco(pp), pp) }
        case ".wrangler": if hasPkg || hasAny(pp, ["wrangler.toml", "wrangler.jsonc"]) { return (.hono, pp) }
        case ".venv", "venv": if has(c.path, "pyvenv.cfg") { return (.python, pp) }
        case ".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache": if pyProject || has(pp, "noxfile.py") { return (.python, pp) }
        case ".gradle": if hasAny(pp, ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]) { return (.jvm, pp) }
        case ".build": if has(pp, "Package.swift") { return (.swift, pp) }
        case "Pods": if has(pp, "Podfile") { return (.swift, pp) }
        case "vendor":
            if has(pp, "go.mod") { return (.go, pp) }
            if has(pp, "composer.json") { return (.other, pp) }
        case "_build", "deps": if has(pp, "mix.exs") { return (.other, pp) }
        case "bin", "obj":
            if let l = try? fm.contentsOfDirectory(atPath: pp), l.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") }) { return (.other, pp) }
        case "build":
            if hasAny(pp, ["build.gradle", "build.gradle.kts"]) { return (.jvm, pp) }
            if hasPkg { return (nodeEco(pp), pp) }
            if pyProject { return (.python, pp) }
        case "dist":
            if hasPkg { return (nodeEco(pp), pp) }
            if pyProject { return (.python, pp) }
        default:
            if nodeNames.contains(c.name), hasPkg { return (nodeEco(pp), pp) }
        }
        return nil
    }

    var out: [Artifact] = []
    var stack = [root]
    while let n = stack.popLast() {
        for c in n.children where c.isDir {
            if n === root && toolHomes.contains(c.name) { continue }
            if candidateNames.contains(c.name), let (eco, proj) = match(c) {
                if c.size >= minSize { out.append(Artifact(id: c.path, eco: eco, name: c.name, project: proj, size: c.size, mtime: c.mtime, global: false)) }
                continue   // non scendere negli artefatti
            }
            stack.append(c)
        }
    }
    return out
}

// MARK: - Cache globali e versioni dei gestori

let globalArtifactPaths: [(Eco, String, String)] = [
    (.node, ".npm/_npx", "Cache npx"),
    (.node, ".npm/_cacache", "Cache npm"),
    (.bun, ".bun/install/cache", "Cache Bun"),
    (.rust, ".cargo/registry", "Cargo registry"),
    (.rust, ".cargo/git", "Cargo git"),
    (.flutter, ".pub-cache", "Pub cache"),
    (.python, "Library/Caches/pip", "Cache pip"),
    (.python, ".cache/uv", "Cache uv"),
    (.go, "go/pkg/mod", "Moduli Go"),
    (.jvm, ".gradle/caches", "Cache Gradle"),
]

struct GItem { let eco: Eco; let path: String; let name: String; let project: String; let global: Bool; let locked: Bool }

private func listDir(_ p: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

private func readTrim(_ p: String) -> String? {
    (try? String(contentsOfFile: p, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Risolve l'alias nvm "default" (anche a catena: lts/* → lts/iron → v20.x) in un nome di cartella.
private func nvmActive(_ home: String, _ versions: [String]) -> String? {
    var cur = readTrim(home + "/.nvm/alias/default")
    for _ in 0..<5 {
        guard let c = cur, !c.isEmpty else { break }
        if versions.contains(c) { return c }
        if let next = readTrim(home + "/.nvm/alias/" + c) { cur = next; continue }
        let want = c.hasPrefix("v") ? c : "v" + c
        if let m = versions.filter({ $0 == want || $0.hasPrefix(want + ".") }).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) { return m }
        if c == "node" || c == "stable" { return versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) }
        break
    }
    return nil
}

func globalItems() -> [GItem] {
    let fm = FileManager.default
    let h = NSHomeDirectory()
    var out: [GItem] = []
    for (eco, rel, name) in globalArtifactPaths where fm.fileExists(atPath: h + "/" + rel) {
        out.append(GItem(eco: eco, path: h + "/" + rel, name: name, project: "Globale", global: true, locked: false))
    }
    // nvm
    let nvmDir = h + "/.nvm/versions/node"
    let nv = listDir(nvmDir)
    let nvA = nvmActive(h, nv)
    for v in nv { out.append(GItem(eco: .runtimes, path: nvmDir + "/" + v, name: "Node " + v, project: "nvm", global: false, locked: v == nvA)) }
    // pyenv
    let pyDir = h + "/.pyenv/versions"
    let pyActive = Set((readTrim(h + "/.pyenv/version") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
    for v in listDir(pyDir) { out.append(GItem(eco: .runtimes, path: pyDir + "/" + v, name: "Python " + v, project: "pyenv", global: false, locked: pyActive.contains(v))) }
    // rustup
    let ruDir = h + "/.rustup/toolchains"
    var ruActive = ""
    if let st = readTrim(h + "/.rustup/settings.toml") {
        for l in st.split(separator: "\n") where l.hasPrefix("default_toolchain") {
            ruActive = l.split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? ""
        }
    }
    for v in listDir(ruDir) { out.append(GItem(eco: .runtimes, path: ruDir + "/" + v, name: "Rust " + v, project: "rustup", global: false, locked: v == ruActive || ruActive.isEmpty)) }
    // fnm
    let fnDir = h + "/.local/share/fnm/node-versions"
    let fnAlias = (try? fm.destinationOfSymbolicLink(atPath: h + "/.local/share/fnm/aliases/default")) ?? ""
    for v in listDir(fnDir) { out.append(GItem(eco: .runtimes, path: fnDir + "/" + v, name: "Node " + v, project: "fnm", global: false, locked: fnAlias.contains("/" + v + "/") || fnAlias.hasSuffix("/" + v) || fnAlias.isEmpty)) }
    return out
}

// MARK: - Controllo progetti attivi

/// Avvisi su progetti che sembrano in uso: processi che puntano al percorso, modifiche git non committate.
func projectWarnings(_ rows: [Artifact]) -> [String] {
    let projects = Array(Set(rows.filter { !$0.global && $0.eco != .runtimes }.map(\.project))).sorted().prefix(60)
    guard !projects.isEmpty else { return [] }
    let ps = shell("/bin/ps", ["-axww", "-o", "command="]).out
    var w: [String] = []
    for p in projects {
        var why: [String] = []
        if ps.contains(p + "/") || ps.contains("cwd=" + p) { why.append("processo in esecuzione") }
        if FileManager.default.fileExists(atPath: p + "/.git") {
            let r = shell("/usr/bin/git", ["-C", p, "--no-optional-locks", "status", "--porcelain"], timeout: 4)
            if r.status == 0, !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { why.append("modifiche git non committate") }
        }
        if !why.isEmpty { w.append("• \(abbreviate(p)): \(why.joined(separator: ", "))") }
    }
    return w
}

// MARK: - Modello

@MainActor
final class ArtifactModel: ObservableObject {
    @Published var rows: [Artifact] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var status = "Premi “Scansiona” per cercare gli artefatti."
    @Published var rootPath = NSHomeDirectory()
    @Published var ecoFilter: Eco?
    @Published var minAgeDays = 0
    @Published var search = ""
    @Published var selection: Set<String> = []
    @Published var busy = false

    private var scanner: Scanner?
    private var timer: Timer?
    private var started = false
    private let measurer = SizeMeasurer()

    func scanIfNeeded() { if !started { scan() } }

    func chooseRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Scansiona"
        if p.runModal() == .OK, let u = p.url { rootPath = u.path; scan() }
    }

    func scan() {
        started = true
        scanner?.cancel(); timer?.invalidate(); measurer.cancel()
        rows = []; selection = []
        scanning = true; progress = "Avvio…"
        let home = NSHomeDirectory()
        // ~/Library e Cestino non contengono progetti: saltarli dimezza i tempi
        let sc = Scanner(path: rootPath, extraSkip: [home + "/Library", home + "/.Trash"])
        scanner = sc
        let t0 = Date()
        sc.onFinish = { [weak self, weak sc] in
            guard let self, let sc, self.scanner === sc else { return }
            self.timer?.invalidate()
            if sc.cancelled { self.scanning = false; return }
            self.progress = "Analisi dei progetti…"
            self.rows = findArtifacts(root: sc.root)
            self.status = String(format: "%d artefatti in %.1f s", self.rows.count, Date().timeIntervalSince(t0))
            self.measureGlobals()
            sc.onFinish = nil
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak sc] _ in
            guard let self, let sc else { return }
            let s = sc.stats
            Task { @MainActor in self.progress = "\(s.files.formatted()) file · \(formatBytes(s.bytes))   \(s.current)" }
        }
        sc.start()
    }

    func cancel() { scanner?.cancel(); timer?.invalidate(); measurer.cancel(); scanning = false; status = "Scansione annullata" }

    private func measureGlobals() {
        let items = globalItems()
        guard !items.isEmpty else { scanning = false; return }
        measurer.onIdle = { [weak self] in self?.scanning = false }
        for g in items {
            measurer.add(g.path) { [weak self] size, _ in
                guard let self, size > 0 else { return }
                self.rows.append(Artifact(id: g.path, eco: g.eco, name: g.name, project: g.project, size: size, mtime: 0, global: g.global, locked: g.locked))
            }
        }
    }

    func filtered(_ order: [KeyPathComparator<Artifact>]) -> [Artifact] {
        let q = search.lowercased()
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(minAgeDays) * 86400
        return rows.filter {
            (ecoFilter == nil || $0.eco == ecoFilter) &&
            (minAgeDays == 0 || $0.mtime == 0 || $0.mtime < cutoff) &&
            (q.isEmpty || $0.id.lowercased().contains(q))
        }.sorted(using: order)
    }

    func total(_ eco: Eco?) -> UInt64 { rows.filter { eco == nil || $0.eco == eco }.reduce(0) { $0 + $1.size } }
    func count(_ eco: Eco) -> Int { rows.filter { $0.eco == eco }.count }

    func exportTable() -> ExportTable {
        ExportTable(headers: ["Tipo", "Artefatto", "Progetto", "Percorso", "Byte", "Dimensione", "Modificata", "Rigenera con"],
                    rows: rows.sorted { $0.size > $1.size }.map { [$0.eco.rawValue, $0.name, $0.project, $0.id, String($0.size), formatBytes($0.size), exportDate($0.mtime), $0.eco.regen] })
    }

    func reveal(_ ids: Set<String>) {
        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
    }

    func trash(_ ids: Set<String>) {
        let all = rows.filter { ids.contains($0.id) }
        let sel = all.filter { !$0.locked }
        let lockedCount = all.count - sel.count
        guard !sel.isEmpty, !busy else {
            if lockedCount > 0 { status = "Le versioni attive sono protette e non vengono cancellate" }
            return
        }
        let total = sel.reduce(0) { $0 + $1.size }
        if dryRunReport(count: sel.count, bytes: total, detail: sel.prefix(10).map { "• \(abbreviate($0.id))" }.joined(separator: "\n")) { return }

        busy = true; status = "Verifica progetti attivi…"
        DispatchQueue.global(qos: .userInitiated).async {
            let warnings = projectWarnings(sel)
            DispatchQueue.main.async { [self] in
                busy = false
                confirmAndTrash(sel, total: total, warnings: warnings, lockedCount: lockedCount)
            }
        }
    }

    private func confirmAndTrash(_ sel: [Artifact], total: UInt64, warnings: [String], lockedCount: Int) {
        let week = Int64(Date().timeIntervalSince1970) - 7 * 86400
        let recent = sel.filter { $0.mtime > week && !$0.global }.count
        let a = NSAlert()
        a.alertStyle = warnings.isEmpty ? .warning : .critical
        a.messageText = sel.count == 1 ? "Spostare “\(sel[0].name)” nel Cestino?" : "Spostare \(sel.count) elementi nel Cestino?"
        var info = sel.prefix(8).map { "• \($0.eco.rawValue) · \(abbreviate($0.id)) — \(formatBytes($0.size))" }.joined(separator: "\n")
        if sel.count > 8 { info += "\n… e altri \(sel.count - 8)" }
        info += "\n\nTotale: \(formatBytes(total)). Si rigenerano con \(Set(sel.map { $0.eco.regen }).sorted().joined(separator: ", "))."
        if lockedCount > 0 { info += "\n🔒 \(lockedCount) versioni attive escluse." }
        if recent > 0 { info += "\n⚠️ \(recent) modificati nell'ultima settimana." }
        if !warnings.isEmpty { info += "\n\n⛔️ Progetti che sembrano in uso:\n" + warnings.prefix(8).joined(separator: "\n") }
        a.informativeText = info
        a.addButton(withTitle: warnings.isEmpty ? "Sposta nel Cestino" : "Sposta comunque")
        a.addButton(withTitle: "Annulla")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }

        busy = true; status = "Spostamento nel Cestino…"
        DispatchQueue.global(qos: .userInitiated).async {
            var done: Set<String> = [], fails: [String] = []
            var log: [TrashEntry] = []
            let fm = FileManager.default
            for r in sel {
                do {
                    if r.global {
                        for kid in (try? fm.contentsOfDirectory(atPath: r.id)) ?? [] { try trashLogged(r.id + "/" + kid, &log) }
                    } else {
                        try trashLogged(r.id, &log)
                    }
                    done.insert(r.id)
                } catch { fails.append("\(abbreviate(r.id)): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async { [self] in
                TrashLog.shared.record("Artefatti", log)
                let freed = sel.filter { done.contains($0.id) }.reduce(0) { $0 + $1.size }
                rows.removeAll { done.contains($0.id) }
                selection.subtract(done)
                busy = false
                status = "Nel Cestino: \(done.count) elementi (\(formatBytes(freed))) · svuota il Cestino per liberare lo spazio" + (fails.isEmpty ? "" : " · \(fails.count) falliti")
                if !fails.isEmpty {
                    let e = NSAlert(); e.messageText = "Alcuni elementi non sono stati spostati"
                    e.informativeText = fails.prefix(6).joined(separator: "\n"); e.runModal()
                }
            }
        }
    }
}

func abbreviate(_ p: String) -> String { p.hasPrefix(NSHomeDirectory()) ? "~" + p.dropFirst(NSHomeDirectory().count) : p }

private let ageFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM/yy"; return f }()

struct ArtefattiView: View {
    @ObservedObject var art: ArtifactModel
    let explore: (String) -> Void
    @State private var order = [KeyPathComparator(\Artifact.size, order: .reverse)]

    var body: some View {
        let rows = art.filtered(order)
        VStack(spacing: 0) {
            chips
            Divider()
            ZStack {
                Table(rows, selection: $art.selection, sortOrder: $order) {
                    TableColumn("Tipo", value: \.ecoName) { r in
                        Text(r.eco.rawValue).font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(r.eco.color.opacity(0.2), in: Capsule())
                    }.width(min: 70, ideal: 90)
                    TableColumn("Artefatto", value: \.name) { r in
                        HStack(spacing: 4) {
                            if r.locked { Image(systemName: "lock.fill").foregroundStyle(.orange).help("Versione attiva: protetta") }
                            Text(r.name).fontWeight(.medium)
                        }
                    }.width(min: 110, ideal: 150)
                    TableColumn("Progetto", value: \.project) { r in
                        Text(abbreviate(r.project)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).help(r.id)
                    }
                    TableColumn("Dimensione", value: \.size) { r in
                        Text(formatBytes(r.size)).font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(r.size > 5 << 30 ? Color.red : r.size > 1 << 30 ? Color.orange : Color.primary)
                    }.width(min: 90, ideal: 100)
                    TableColumn("Modificata", value: \.mtimeSort) { r in
                        Text(r.mtime == 0 ? "—" : ageFmt.string(from: Date(timeIntervalSince1970: TimeInterval(r.mtime)))).foregroundStyle(.secondary)
                    }.width(min: 80, ideal: 90)
                    TableColumn("Rigenera con") { r in
                        Text(r.locked ? "ATTIVA · protetta" : r.global ? "automatico" : r.eco.regen).foregroundStyle(r.locked ? Color.orange : .secondary)
                    }.width(min: 110, ideal: 140)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Mostra nel Finder") { art.reveal(ids) }
                    if ids.count == 1, let id = ids.first, let r = art.rows.first(where: { $0.id == id }), !r.global {
                        Button("Esplora nella Lista") { explore(id) }
                    }
                    Divider()
                    Button("Sposta nel Cestino…") { art.trash(ids) }
                }
                if art.scanning {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Ricerca artefatti…").font(.headline)
                        Text(art.progress).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).frame(maxWidth: 560)
                        Button("Annulla") { art.cancel() }
                    }
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else if rows.isEmpty {
                    Text("Nessun artefatto trovato con questi filtri").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 14) {
                if art.selection.isEmpty { Text(art.status) } else {
                    let sel = art.rows.filter { art.selection.contains($0.id) }
                    Text("\(sel.count) selezionati · \(formatBytes(sel.reduce(0) { $0 + $1.size }))").fontWeight(.medium)
                }
                Spacer()
                Text("Visibili: \(formatBytes(rows.reduce(0) { $0 + $1.size }))")
                Text("Radice: \(abbreviate(art.rootPath))")
            }
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear { art.scanIfNeeded() }
        .searchable(text: $art.search, placement: .toolbar, prompt: "Cerca per progetto o percorso")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Scegli cartella…") { art.chooseRoot() }
                    Divider()
                    VolumeMenuItems { art.rootPath = $0; art.scan() }
                } label: { Label("Cartella", systemImage: "folder") }.help("Scegli cartella o disco da scansionare")
                Button { art.scan() } label: { Label("Riscansiona", systemImage: "arrow.clockwise") }.disabled(art.scanning)
                Picker("Non toccati da", selection: $art.minAgeDays) {
                    Text("Qualsiasi data").tag(0)
                    Text("> 30 giorni").tag(30)
                    Text("> 90 giorni").tag(90)
                    Text("> 180 giorni").tag(180)
                    Text("> 1 anno").tag(365)
                }.help("Mostra solo artefatti non modificati da…")
                Button { art.selection = Set(rows.filter { !$0.global && !$0.locked }.map(\.id)) } label: { Label("Seleziona visibili", systemImage: "checklist") }
                    .help("Seleziona tutti gli artefatti di progetto visibili (escluse versioni attive)")
                Button(role: .destructive) { art.trash(art.selection) } label: { Label("Sposta nel Cestino", systemImage: "trash") }
                    .disabled(art.selection.isEmpty || art.busy)
                GlobalToolbarButtons()
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "Tutti", art.total(nil), art.rows.count)
                ForEach(Eco.allCases.filter { art.count($0) > 0 }) { e in chip(e, e.rawValue, art.total(e), art.count(e)) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func chip(_ eco: Eco?, _ title: String, _ bytes: UInt64, _ n: Int) -> some View {
        let on = art.ecoFilter == eco
        return Button { art.ecoFilter = eco } label: {
            HStack(spacing: 6) {
                if let eco { Circle().fill(eco.color).frame(width: 8, height: 8) }
                Text(title).fontWeight(.medium)
                Text("\(formatBytes(bytes)) · \(n)").foregroundStyle(.secondary)
            }
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
            .background(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(on ? Color.accentColor : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}
