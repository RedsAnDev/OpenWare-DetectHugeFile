import Foundation

// Server MCP (Model Context Protocol) su stdio: `DetectHugeFile --mcp`.
//
// Regole di progetto:
//  • stdout contiene SOLO messaggi JSON-RPC (una riga ciascuno); ogni log va su stderr.
//  • Gli strumenti di analisi sono di sola lettura.
//  • L'unico strumento che modifica il disco, `trash_paths`, sposta nel Cestino (mai rm) e solo dopo una
//    conferma mostrata all'utente in una finestra di sistema, costruita dal server con i percorsi reali:
//    il modello non può né vederla né rispondere al posto dell'utente.

typealias JSON = [String: Any]

struct ToolError: Error { let message: String; init(_ m: String) { message = m } }

private func log(_ s: String) { FileHandle.standardError.write(Data(("[mcp] " + s + "\n").utf8)) }

// MARK: - Utilità

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { if let i = self[k] as? Int { return i }; if let d = self[k] as? Double { return Int(d) }; return nil }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func strs(_ k: String) -> [String]? { self[k] as? [String] }
}

private let isoFmt = ISO8601DateFormatter()
private func isoDate(_ t: Int64) -> String { t == 0 ? "" : isoFmt.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }

private func resolvePath(_ p: String?) -> String {
    let raw = p?.trimmingCharacters(in: .whitespaces) ?? ""
    return raw.isEmpty ? NSHomeDirectory() : (raw as NSString).expandingTildeInPath
}

private func human(_ b: UInt64) -> String { formatBytes(b) }

// MARK: - Scansioni sincrone con cache (il server è un processo lungo: evita di rifare scansioni da 40 s)

final class ScanCache {
    static let shared = ScanCache()
    private let lock = NSLock()
    private var store: [String: (Date, Node)] = [:]

    func get(_ key: String, maxAge: TimeInterval) -> Node? {
        lock.lock(); defer { lock.unlock() }
        if let (t, n) = store[key], Date().timeIntervalSince(t) < maxAge { return n }
        return nil
    }
    func put(_ key: String, _ n: Node) { lock.lock(); store[key] = (Date(), n); lock.unlock() }
    func clear() { lock.lock(); store = [:]; lock.unlock() }
}

func scanSync(_ path: String, extraSkip: Set<String> = [], threshold: UInt64 = 10 << 20) -> Node {
    let sc = Scanner(path: path, extraSkip: extraSkip, bigFileThreshold: threshold)
    let sem = DispatchSemaphore(value: 0)
    sc.onFinish = { sem.signal() }
    sc.start()
    sem.wait()                 // onFinish arriva dal main queue: il main thread è libero (dispatchMain)
    sc.onFinish = nil
    return sc.root
}

func cachedScan(_ path: String, extraSkip: Set<String> = [], threshold: UInt64 = 10 << 20, fresh: Bool = false) -> (node: Node, cached: Bool, seconds: Double) {
    let key = "\(path)|\(extraSkip.sorted())|\(threshold)"
    if !fresh, let n = ScanCache.shared.get(key, maxAge: 600) { return (n, true, 0) }
    let t0 = Date()
    let n = scanSync(path, extraSkip: extraSkip, threshold: threshold)
    ScanCache.shared.put(key, n)
    return (n, false, Date().timeIntervalSince(t0))
}

private func libSkip() -> Set<String> { let h = NSHomeDirectory(); return [h + "/Library", h + "/.Trash"] }

private func requireExists(_ path: String) throws {
    guard FileManager.default.fileExists(atPath: path) else { throw ToolError("Percorso inesistente: \(path)") }
}

// MARK: - Strumenti di sola lettura

func toolListVolumes(_ a: JSON) throws -> Any {
    ["volumes": currentVolumes().map { v -> JSON in
        ["name": v.name, "path": v.path, "total_bytes": v.total, "free_bytes": v.free, "total": human(v.total), "free": human(v.free),
         "internal": v.isInternal, "ejectable": v.ejectable, "format": v.format]
    }]
}

func toolScanFolders(_ a: JSON) throws -> Any {
    let path = resolvePath(a.str("path"))
    try requireExists(path)
    let top = max(1, min(200, a.int("top") ?? 25))
    let minB = UInt64(max(0, a.int("min_mb") ?? 10)) << 20
    let maxDepth = a.int("max_depth")
    let withFiles = a.bool("include_files") ?? false
    let (root, cached, secs) = cachedScan(path, fresh: a.bool("fresh") ?? false)

    if (a.bool("save_snapshot") ?? true) && !cached {
        let s = Snapshot.make(root: root)
        SnapshotStore.write(s)
        SnapshotStore.prune(root: s.root)
    }

    var rows: [(Node, Int)] = []
    var denied = 0
    var stack: [(Node, Int)] = [(root, 0)]
    while let (n, d) = stack.popLast() {
        if n.denied { denied += 1 }
        if n.size >= minB && (n.isDir || withFiles) { rows.append((n, d)) }
        if let m = maxDepth, d >= m { continue }
        for c in n.children where c.isDir || withFiles { stack.append((c, d + 1)) }
    }
    rows.sort { $0.0.size > $1.0.size }
    var out: JSON = [
        "path": path, "total_bytes": root.size, "total": human(root.size), "files": root.files,
        "scan_seconds": (secs * 10).rounded() / 10, "from_cache": cached, "access_denied_dirs": denied,
        "folders": rows.prefix(top).map { (n, d) -> JSON in
            var j: JSON = ["path": n.path, "size_bytes": n.size, "size": human(n.size), "files": n.files,
                           "modified": isoDate(n.mtime), "kind": n.isDir ? "dir" : "file", "depth": d]
            if let h = regenerableHints[n.name], n.isDir { j["hint"] = h }
            return j
        },
    ]
    if denied > 0 { out["note"] = "\(denied) cartelle non leggibili: manca l'Accesso completo al disco per il processo che avvia il server." }
    return out
}

private func artifactJSON(_ r: Artifact) -> JSON {
    ["path": r.id, "ecosystem": r.eco.rawValue, "name": r.name, "project": r.project, "size_bytes": r.size, "size": human(r.size),
     "modified": isoDate(r.mtime), "regenerate_with": r.eco.regen, "global_cache": r.global, "locked": r.locked,
     "trashable_with_trash_paths": !r.locked]
}

func gatherArtifacts(root rootPath: String, includeGlobal: Bool, fresh: Bool) -> (rows: [Artifact], cached: Bool, seconds: Double) {
    let (node, cached, secs) = cachedScan(rootPath, extraSkip: libSkip(), fresh: fresh)
    var rows = findArtifacts(root: node)
    if includeGlobal {
        for g in globalItems() {
            let sz = cachedScan(g.path).node.size
            if sz > 0 { rows.append(Artifact(id: g.path, eco: g.eco, name: g.name, project: g.project, size: sz, mtime: 0, global: g.global, locked: g.locked)) }
        }
    }
    return (rows, cached, secs)
}

func toolFindArtifacts(_ a: JSON) throws -> Any {
    let root = resolvePath(a.str("root"))
    try requireExists(root)
    let minAge = a.int("min_age_days") ?? 0
    let limit = max(1, min(300, a.int("limit") ?? 60))
    let wanted = Set((a.strs("ecosystems") ?? []).map { $0.lowercased() })
    let (all, cached, secs) = gatherArtifacts(root: root, includeGlobal: a.bool("include_global") ?? true, fresh: a.bool("fresh") ?? false)
    let cutoff = Int64(Date().timeIntervalSince1970) - Int64(minAge) * 86400
    let rows = all.filter { (wanted.isEmpty || wanted.contains($0.eco.rawValue.lowercased())) && (minAge == 0 || $0.mtime == 0 || $0.mtime < cutoff) }
        .sorted { $0.size > $1.size }
    var byEco: [String: JSON] = [:]
    for r in rows {
        var e = byEco[r.eco.rawValue] ?? ["count": 0, "bytes": UInt64(0)]
        e["count"] = (e["count"] as! Int) + 1
        e["bytes"] = (e["bytes"] as! UInt64) + r.size
        byEco[r.eco.rawValue] = e
    }
    return ["root": root, "scan_seconds": (secs * 10).rounded() / 10, "from_cache": cached, "count": rows.count,
            "total_bytes": rows.reduce(0) { $0 + $1.size }, "total": human(rows.reduce(0) { $0 + $1.size }),
            "by_ecosystem": byEco, "artifacts": rows.prefix(limit).map(artifactJSON),
            "note": "I progetti attivi (processi in esecuzione, modifiche Git non committate) vanno controllati prima di cancellare."] as JSON
}

func toolFindDuplicates(_ a: JSON) throws -> Any {
    let root = resolvePath(a.str("root"))
    try requireExists(root)
    let minMB = max(1, a.int("min_mb") ?? 5)
    let limit = max(1, min(100, a.int("limit") ?? 25))
    let (node, _, secs) = cachedScan(root, extraSkip: libSkip(), threshold: UInt64(minMB) << 20, fresh: a.bool("fresh") ?? false)
    var files: [(String, UInt64, Int64)] = []
    var stack = [node]
    while let n = stack.popLast() {
        for c in n.children {
            if c.isDir { if c.name != "node_modules" && c.name != ".git" { stack.append(c) } }
            else { files.append((c.path, c.size, c.mtime)) }
        }
    }
    let groups = computeDuplicates(files, state: DupState())
    return ["root": root, "min_mb": minMB, "files_compared": files.count, "scan_seconds": (secs * 10).rounded() / 10,
            "groups": groups.count, "wasted_bytes": groups.reduce(0) { $0 + $1.wasted }, "wasted": human(groups.reduce(0) { $0 + $1.wasted }),
            "duplicates": groups.prefix(limit).map { g -> JSON in
                ["size_bytes": g.size, "size": human(g.size), "copies": g.files.count, "wasted_bytes": g.wasted, "wasted": human(g.wasted),
                 "files": g.files.map { ["path": $0.id, "modified": isoDate($0.mtime)] as JSON }]
            },
            "note": "Gli hash sono SHA-256 completi. I cloni APFS condividono lo spazio e risultano comunque come duplicati. Tenere sempre almeno una copia per gruppo."] as JSON
}

func toolKnownOffenders(_ a: JSON) throws -> Any {
    let minMB = a.int("min_mb") ?? 20
    var rows: [JSON] = []
    for it in knownItems where FileManager.default.fileExists(atPath: it.path) {
        let n = cachedScan(it.path, fresh: a.bool("fresh") ?? false).node
        guard n.size >= UInt64(minMB) << 20 else { continue }
        let mode: String
        switch it.mode {
        case .contents: mode = "trash_contents"
        case .emptyTrash: mode = "empty_trash"
        case .command(let c): mode = "command: " + (c.components(separatedBy: "; ").last ?? c)
        case .manual(let h): mode = "manual: " + h
        }
        rows.append(["category": it.category, "title": it.title, "path": it.path, "size_bytes": n.size, "size": human(n.size),
                     "risk": it.risk == .safe ? "safe" : "caution", "clean_mode": mode, "note": it.note, "access_denied": n.denied && n.size == 0])
    }
    rows.sort { ($0["size_bytes"] as! UInt64) > ($1["size_bytes"] as! UInt64) }
    return ["items": rows, "total_bytes": rows.reduce(0) { $0 + ($1["size_bytes"] as! UInt64) }] as JSON
}

func toolContainersSummary(_ a: JSON) throws -> Any {
    var engines: [JSON] = []
    var items: [CItem] = []
    var podmanIDs: Set<String> = []
    for (name, bin) in [("podman", findBinary("podman")), ("docker", findBinary("docker"))] {
        guard let bin else { engines.append(["engine": name, "installed": false]); continue }
        var (e, it, ids) = loadEngine(name, bin)
        var note = e.note ?? ""
        if name == "podman" { podmanIDs = ids }
        else if !podmanIDs.isEmpty, !ids.isDisjoint(with: podmanIDs) { it = []; note = "Il CLI docker usa il socket di Podman: stessi dati." }
        items += it
        engines.append(["engine": name, "installed": true, "version": e.version, "error": e.error ?? "", "note": note,
                        "df": e.summary.map { ["type": $0.label, "total": $0.total, "size": $0.size, "reclaimable": $0.reclaim] }])
    }
    items += loadMinikube(volumesByName: [:])
    func rows(_ s: CSection, _ n: Int) -> [JSON] {
        items.filter { $0.section == s }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(n).map {
            ["engine": $0.engine, "name": $0.title, "details": $0.subtitle, "size_bytes": $0.size ?? 0, "size": human($0.size ?? 0),
             "in_use": $0.inUse, "minikube": $0.minikube]
        }
    }
    var out: JSON = ["engines": engines, "containers": rows(.container, 50), "images": rows(.image, 20), "volumes": rows(.volume, 30), "minikube": rows(.minikube, 10),
                     "note": "Le azioni (prune, rm, compattazione VM) non sono esposte via MCP: si fanno dalla tab Container dell'app. I volumi contengono dati persistenti."]
    if let vm = podmanVMDisk() {
        out["podman_vm_disk"] = ["path": vm.path, "allocated_bytes": vm.allocated, "allocated": human(vm.allocated), "logical": human(vm.logical),
                                 "hint": "Non si restringe da sola dopo aver eliminato immagini: serve `podman machine ssh sudo fstrim -av`."] as JSON
    }
    return out
}

func toolBrewSummary(_ a: JSON) throws -> Any {
    guard let b = brewBinary() else { throw ToolError("Homebrew non trovato") }
    let limit = max(1, min(200, a.int("limit") ?? 40))
    var items = parseBrewInfo(brewRun(b, ["info", "--json=v2", "--installed"], timeout: 120).out)
    let prefix = brewRun(b, ["--prefix"], timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines)
    for (dir, cask) in [(prefix + "/Cellar", false), (prefix + "/Caskroom", true)] {
        let sizes = Dictionary(cachedScan(dir).node.children.map { ($0.name, $0.size) }, uniquingKeysWith: max)
        for i in items.indices where items[i].isCask == cask { items[i].size += sizes[items[i].name] ?? 0 }
    }
    for i in items.indices where items[i].isCask {
        for app in items[i].apps where FileManager.default.fileExists(atPath: "/Applications/" + app) {
            items[i].size += cachedScan("/Applications/" + app).node.size
        }
    }
    let cleanup = brewRun(b, ["cleanup", "-n", "-s", "--prune=all"], timeout: 60).out
    let est = cleanup.split(separator: "\n").last(where: { $0.contains("free approximately") }).map(String.init) ?? ""
    var auto: [String] = [], capture = false
    for l in brewRun(b, ["autoremove", "-n"], timeout: 60).out.split(separator: "\n") {
        if l.contains("Would autoremove") { capture = true; continue }
        if capture, !l.hasPrefix("==>"), !l.isEmpty { auto.append(String(l)) }
    }
    let sorted = items.sorted { $0.size > $1.size }
    return ["formulae": items.filter { !$0.isCask }.count, "casks": items.filter { $0.isCask }.count,
            "explicit_formulae": items.filter { !$0.isCask && $0.leaf }.count, "total_bytes": items.reduce(0) { $0 + $1.size },
            "cleanup_estimate": est, "autoremove_candidates": auto,
            "largest": sorted.prefix(limit).map { i -> JSON in
                ["name": i.name, "kind": i.kind, "version": i.version, "size_bytes": i.size, "size": human(i.size),
                 "required_by": i.usedBy, "uninstallable": i.removable, "description": i.desc]
            },
            "note": "Le azioni (uninstall, cleanup, autoremove) non sono esposte via MCP: si fanno dalla tab Homebrew dell'app."] as JSON
}

func toolCompareSnapshots(_ a: JSON) throws -> Any {
    let all = SnapshotStore.loadAll()
    let root = a.str("root").map { resolvePath($0) }
    let pool = root.map { r in all.filter { $0.root == r } } ?? all
    func brief(_ s: Snapshot) -> JSON { ["id": String(s.id.uuidString.prefix(8)), "date": isoFmt.string(from: s.date), "root": s.root, "total_bytes": s.total, "total": human(s.total)] }
    func pick(_ key: String?, _ fallback: Int) -> Snapshot? {
        guard let key, !key.isEmpty else { return pool.indices.contains(pool.count - fallback) ? pool[pool.count - fallback] : nil }
        if key == "latest" { return pool.last }
        if key == "previous" { return pool.count >= 2 ? pool[pool.count - 2] : nil }
        return pool.first { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }
    }
    guard pool.count >= 2, let from = pick(a.str("from"), 2), let to = pick(a.str("to"), 1), from.id != to.id else {
        return ["snapshots": pool.map(brief),
                "note": "Servono almeno due istantanee della stessa radice. Ogni scan_folders (o scansione nell'app) ne salva una: ripeti la scansione più tardi."] as JSON
    }
    let minMB = a.int("min_mb") ?? 20
    let rows = computeDeltas(from, to, minMB: minMB, onlyGrown: a.bool("only_grown") ?? false).sorted { $0.delta > $1.delta }
    let limit = max(1, min(200, a.int("limit") ?? 40))
    return ["from": brief(from), "to": brief(to), "total_delta_bytes": Int64(to.total) - Int64(from.total),
            "changes": rows.prefix(limit).map { r -> JSON in
                ["path": r.path, "before_bytes": r.before, "after_bytes": r.after, "delta_bytes": r.delta,
                 "delta": (r.delta < 0 ? "-" : "+") + human(UInt64(abs(r.delta))), "new": r.before == 0, "removed": r.after == 0]
            },
            "available_snapshots": pool.map(brief)] as JSON
}

// MARK: - plan_cleanup (nessuna modifica)

func toolPlanCleanup(_ a: JSON) throws -> Any {
    let root = resolvePath(a.str("root"))
    try requireExists(root)
    let minAge = a.int("min_age_days") ?? 90
    let goalGB = (a["goal_gb"] as? Double) ?? (a.int("goal_gb").map(Double.init))
    let (all, _, _) = gatherArtifacts(root: root, includeGlobal: true, fresh: false)
    let cutoff = Int64(Date().timeIntervalSince1970) - Int64(minAge) * 86400

    var actionable: [JSON] = []
    for r in all where !r.locked && r.size >= 50 << 20 {
        let old = r.mtime == 0 || r.mtime < cutoff
        if !old { continue }
        let reason: String, risk: String
        if r.eco == .runtimes {
            reason = "Versione non attiva di \(r.name) (gestita da \(r.project)): si reinstalla quando serve. Verifica che nessun progetto la richieda (.nvmrc, rust-toolchain, .python-version)."
            risk = "medium"
        } else if r.global {
            reason = "Cache globale \(r.eco.rawValue) (\(r.name)): si rigenera da sola."
            risk = "low"
        } else {
            let days = Int((Date().timeIntervalSince1970 - Double(r.mtime)) / 86400)
            reason = "Artefatto \(r.eco.rawValue) del progetto \(abbreviate(r.project)), non toccato da \(days) giorni; si rigenera con `\(r.eco.regen)`."
            risk = "low-medium"
        }
        actionable.append(["path": r.id, "bytes": r.size, "size": human(r.size), "reason": reason, "risk": risk,
                           "reversible": true, "via": "trash_paths", "ecosystem": r.eco.rawValue])
    }
    actionable.sort { ($0["bytes"] as! UInt64) > ($1["bytes"] as! UInt64) }

    // selezione suggerita: dal più grande finché si raggiunge l'obiettivo
    var picked: [String] = [], acc: UInt64 = 0
    let goalB = goalGB.map { UInt64($0 * 1_000_000_000) }
    for c in actionable {
        if let g = goalB, acc >= g { break }
        picked.append(c["path"] as! String); acc += c["bytes"] as! UInt64
        if picked.count >= 40 { break }
    }

    // opportunità non eseguibili via MCP (si fanno dall'app)
    var manual: [JSON] = []
    for it in knownItems where it.risk == .safe && FileManager.default.fileExists(atPath: it.path) {
        if case .manual = it.mode { continue }
        let n = cachedScan(it.path).node
        if n.size >= 200 << 20 {
            manual.append(["title": it.title, "path": it.path, "bytes": n.size, "size": human(n.size), "where": "app → tab WellKnown", "note": it.note])
        }
    }
    for e in [("podman", findBinary("podman")), ("docker", findBinary("docker"))] {
        guard let bin = e.1 else { continue }
        let df = parseDFSummary(shell(bin, ["system", "df"], timeout: 30).out)
        for r in df where r.label == "Images" || r.label == "Local Volumes" {
            manual.append(["title": "\(e.0): \(r.label) recuperabili", "bytes": parseSize(r.reclaim.components(separatedBy: " ").first ?? "") ?? 0,
                           "size": r.reclaim, "where": "app → tab Container → Pulizia", "note": r.label == "Local Volumes" ? "I volumi contengono dati: verificare prima." : "Immagini non usate."])
        }
    }
    if let vm = podmanVMDisk() {
        manual.append(["title": "Disco VM Podman (dopo la pulizia, compattare)", "bytes": vm.allocated, "size": human(vm.allocated), "where": "app → tab Container → Compatta disco VM",
                       "note": "Il file occupa davvero questo spazio sul Mac e non si restringe da solo."])
    }
    if let b = brewBinary() {
        let est = brewRun(b, ["cleanup", "-n", "-s", "--prune=all"], timeout: 60).out.split(separator: "\n").last(where: { $0.contains("free approximately") }).map(String.init) ?? ""
        if !est.isEmpty { manual.append(["title": "Homebrew cleanup", "size": est, "where": "app → tab Homebrew → Cleanup", "note": "Vecchie versioni e cache."]) }
    }

    return ["root": root, "min_age_days": minAge, "goal_gb": goalGB as Any? ?? NSNull(),
            "actionable_total_bytes": actionable.reduce(0) { $0 + ($1["bytes"] as! UInt64) },
            "actionable": Array(actionable.prefix(60)),
            "suggested_paths": picked, "suggested_total_bytes": acc, "suggested_total": human(acc),
            "manual_opportunities": manual,
            "next_step": "Mostra il piano all'utente. Per eseguire, chiama trash_paths con i percorsi scelti: l'utente dovrà confermare in una finestra di sistema. Nulla è stato modificato."] as JSON
}

// MARK: - trash_paths (unico strumento che modifica)

func asString(_ lines: [String]) -> String {
    lines.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: " & return & ")
}

/// Finestra di conferma nativa. `DHF_MCP_CONFIRM=deny` forza il rifiuto (test); non esiste una variante che approva.
func confirmWithUser(_ lines: [String]) -> Bool {
    if ProcessInfo.processInfo.environment["DHF_MCP_CONFIRM"] == "deny" { return false }
    let timeout = Int(ProcessInfo.processInfo.environment["DHF_MCP_CONFIRM_TIMEOUT"] ?? "") ?? 180
    let script = "display dialog \(asString(lines)) with title \"DetectHugeFile — richiesta di Claude\" buttons {\"Annulla\", \"Sposta nel Cestino\"} default button \"Annulla\" cancel button \"Annulla\" with icon caution giving up after \(timeout)"
    let r = shell("/usr/bin/osascript", ["-e", script], timeout: TimeInterval(timeout + 15))
    return parseDialogResult(status: r.status, out: r.out)
}

func parseDialogResult(status: Int32, out: String) -> Bool {
    status == 0 && out.contains("button returned:Sposta nel Cestino") && !out.contains("gave up:true")
}

struct TrashTarget { let path: String; let size: UInt64; let isDir: Bool }

func validateTrashPaths(_ raw: [String]) throws -> [TrashTarget] {
    guard !raw.isEmpty else { throw ToolError("Nessun percorso indicato") }
    guard raw.count <= 50 else { throw ToolError("Massimo 50 percorsi per richiesta") }
    var paths: [String] = []
    for r in raw {
        let p = (r as NSString).expandingTildeInPath
        guard p.hasPrefix("/") else { throw ToolError("Percorso non assoluto: \(r)") }
        let std = (p as NSString).standardizingPath
        var st = stat()
        guard lstat(std, &st) == 0 else { throw ToolError("Percorso inesistente: \(std)") }
        if isProtectedPath(std) { throw ToolError("Percorso protetto, non può essere spostato nel Cestino: \(std)") }
        paths.append(std)
    }
    // versioni attive dei gestori (nvm, pyenv, rustup, fnm): mai
    let locked = Set(globalItems().filter { $0.locked }.map { $0.path })
    if let l = paths.first(where: { p in locked.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) }) {
        throw ToolError("Versione attiva di un gestore (nvm/pyenv/rustup/fnm), protetta: \(l)")
    }
    // elimina duplicati e figli di percorsi già presenti
    let uniq = Array(Set(paths)).sorted()
    let top = uniq.filter { p in !uniq.contains { $0 != p && p.hasPrefix($0 + "/") } }
    return top.map { p in
        var st = stat(); lstat(p, &st)
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let size = isDir ? scanSync(p).size : UInt64(st.st_blocks) * 512
        return TrashTarget(path: p, size: size, isDir: isDir)
    }
}

/// Esegue lo spostamento (già confermato). Registra nel registro condiviso per il ripristino.
func executeTrash(_ targets: [TrashTarget], label: String) -> JSON {
    var log: [TrashEntry] = []
    var moved: [JSON] = [], failed: [JSON] = []
    for t in targets {
        do { try trashLogged(t.path, &log); moved.append(["path": t.path, "size_bytes": t.size]) }
        catch { failed.append(["path": t.path, "error": error.localizedDescription]) }
    }
    TrashLogStore.append(label, log)
    ScanCache.shared.clear()
    let freed = moved.reduce(UInt64(0)) { $0 + ($1["size_bytes"] as! UInt64) }
    return ["moved": moved, "failed": failed, "moved_bytes": freed, "moved_size": human(freed),
            "note": "Elementi nel Cestino: lo spazio si libera svuotandolo. Per annullare usa restore_last."]
}

func toolTrashPaths(_ a: JSON) throws -> Any {
    let raw = a.strs("paths") ?? []
    let reasonRaw = (a.str("reason") ?? "").filter { !$0.isASCII || $0 >= " " }
    let reason = String(reasonRaw.prefix(200))
    let targets = try validateTrashPaths(raw)
    let total = targets.reduce(0) { $0 + $1.size }

    if UserDefaults(suiteName: "dev.rossiandrea.DetectHugeFile")?.bool(forKey: "dryRun") == true {
        return ["dry_run": true, "would_move": targets.map { ["path": $0.path, "size_bytes": $0.size] as JSON }, "would_free_bytes": total,
                "note": "Modalità a secco attiva nell'app: nessun file è stato toccato."] as JSON
    }

    var lines = ["Claude chiede di spostare nel Cestino \(targets.count) elementi (\(human(total))):", ""]
    lines += targets.prefix(12).map { "• \(abbreviate($0.path)) — \(human($0.size))" }
    if targets.count > 12 { lines.append("… e altri \(targets.count - 12)") }
    lines += ["", "Sono recuperabili dal Cestino (e con “Ripristina” nell'app)."]
    if !reason.isEmpty { lines += ["", "Motivo indicato da Claude: «\(reason)»"] }
    guard confirmWithUser(lines) else {
        return ["confirmed": false, "moved": [], "note": "L'utente ha rifiutato o non ha risposto: nessun file è stato toccato. Non insistere senza che l'utente lo chieda."] as JSON
    }
    var out = executeTrash(targets, label: "Claude (MCP)")
    out["confirmed"] = true
    return out
}

func toolRestoreLast(_ a: JSON) throws -> Any {
    ["result": TrashLogStore.restoreLast()]
}

// MARK: - Registro degli strumenti

struct MCPTool {
    let name: String
    let description: String
    let properties: JSON
    let required: [String]
    let readOnly: Bool
    let destructive: Bool
    let handler: (JSON) throws -> Any

    var definition: JSON {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as JSON,
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "idempotentHint": readOnly, "openWorldHint": false] as JSON]
    }
}

private func prop(_ type: String, _ desc: String) -> JSON { ["type": type, "description": desc] }

let mcpTools: [MCPTool] = [
    MCPTool(name: "list_volumes", description: "Elenca i dischi montati (interni, USB, SD) con spazio totale e libero.",
            properties: [:], required: [], readOnly: true, destructive: false, handler: toolListVolumes),
    MCPTool(name: "scan_folders",
            description: "Scansiona un percorso (default: home) e restituisce le cartelle più pesanti, con dimensione allocata su disco (come du). Può richiedere fino a ~1 minuto per una home grande; i risultati sono in cache 10 minuti. Salva anche un'istantanea per compare_snapshots.",
            properties: ["path": prop("string", "Cartella o volume da scansionare (default: home). Accetta ~."),
                         "top": prop("integer", "Quante voci restituire (default 25, max 200)."),
                         "min_mb": prop("integer", "Dimensione minima in MB (default 10)."),
                         "max_depth": prop("integer", "Profondità massima rispetto al percorso (opzionale)."),
                         "include_files": prop("boolean", "Includi anche i singoli file da 10 MB in su (default false)."),
                         "save_snapshot": prop("boolean", "Salva un'istantanea per i confronti (default true)."),
                         "fresh": prop("boolean", "Ignora la cache e riscansiona.")],
            required: [], readOnly: true, destructive: false, handler: toolScanFolders),
    MCPTool(name: "find_artifacts",
            description: "Trova artefatti rigenerabili di progetto (node_modules, target, build, .venv, Pods…) di Node, Bun, Hono, Rust, Flutter, Python, Java/Gradle, Swift, Go, più cache globali e versioni dei gestori (nvm, pyenv, rustup, fnm; l'attiva è 'locked'). Riconosciuti dal manifest accanto (package.json, Cargo.toml…).",
            properties: ["root": prop("string", "Cartella radice (default: home; ~/Library è esclusa)."),
                         "min_age_days": prop("integer", "Solo artefatti non modificati da almeno N giorni."),
                         "ecosystems": ["type": "array", "items": ["type": "string"], "description": "Filtra: Node, Bun, Hono, Rust, Flutter, Python, Java/Gradle, Swift/Pods, Go, Altri, Versioni."] as JSON,
                         "include_global": prop("boolean", "Includi cache globali e versioni dei gestori (default true)."),
                         "limit": prop("integer", "Massimo di voci (default 60)."),
                         "fresh": prop("boolean", "Ignora la cache.")],
            required: [], readOnly: true, destructive: false, handler: toolFindArtifacts),
    MCPTool(name: "find_duplicates",
            description: "Trova file duplicati: stessa dimensione, poi hash del primo MB, poi SHA-256 completo. Esclude node_modules, .git e ~/Library.",
            properties: ["root": prop("string", "Cartella radice (default: home)."),
                         "min_mb": prop("integer", "Dimensione minima dei file in MB (default 5)."),
                         "limit": prop("integer", "Quanti gruppi restituire (default 25)."),
                         "fresh": prop("boolean", "Ignora la cache.")],
            required: [], readOnly: true, destructive: false, handler: toolFindDuplicates),
    MCPTool(name: "known_offenders",
            description: "I 'colpevoli noti' di macOS che di solito si svuotano per recuperare spazio (cache, log, DerivedData, cache npm/Gradle/Cargo, modelli AI…) con dimensione, rischio e modo di pulizia.",
            properties: ["min_mb": prop("integer", "Dimensione minima in MB (default 20)."), "fresh": prop("boolean", "Ignora la cache.")],
            required: [], readOnly: true, destructive: false, handler: toolKnownOffenders),
    MCPTool(name: "containers_summary",
            description: "Riepilogo di Docker, Podman e minikube: container, immagini, volumi, spazio recuperabile e dimensione reale del disco della VM di Podman. Sola lettura.",
            properties: [:], required: [], readOnly: true, destructive: false, handler: toolContainersSummary),
    MCPTool(name: "brew_summary",
            description: "Riepilogo di Homebrew: formule e cask più pesanti, quali sono richieste da altre, stima del cleanup e dipendenze orfane (autoremove). Sola lettura.",
            properties: ["limit": prop("integer", "Quanti pacchetti restituire (default 40).")],
            required: [], readOnly: true, destructive: false, handler: toolBrewSummary),
    MCPTool(name: "compare_snapshots",
            description: "Confronta due istantanee di scansione e mostra quali cartelle sono cresciute o diminuite. Senza parametri confronta le ultime due della stessa radice.",
            properties: ["root": prop("string", "Radice delle istantanee da considerare."),
                         "from": prop("string", "id (prefisso), 'previous' o 'latest'."),
                         "to": prop("string", "id (prefisso) o 'latest'."),
                         "min_mb": prop("integer", "Variazione minima in MB (default 20)."),
                         "only_grown": prop("boolean", "Solo le crescite."),
                         "limit": prop("integer", "Massimo di righe (default 40).")],
            required: [], readOnly: true, destructive: false, handler: toolCompareSnapshots),
    MCPTool(name: "plan_cleanup",
            description: "Propone un piano di pulizia SENZA modificare nulla: candidati eseguibili con trash_paths (artefatti e cache vecchi, con motivazione e rischio) e opportunità da fare a mano nell'app (container, Homebrew, cache note). Con goal_gb suggerisce una selezione.",
            properties: ["root": prop("string", "Cartella radice dei progetti (default: home)."),
                         "goal_gb": prop("number", "Obiettivo di spazio da recuperare, in GB (opzionale)."),
                         "min_age_days": prop("integer", "Età minima degli artefatti (default 90).")],
            required: [], readOnly: true, destructive: false, handler: toolPlanCleanup),
    MCPTool(name: "trash_paths",
            description: "Sposta nel Cestino file o cartelle (mai eliminazione definitiva). L'UTENTE DEVE CONFERMARE in una finestra di sistema che mostra i percorsi reali e le dimensioni: la richiesta può essere rifiutata o scadere (180 s). Rifiuta percorsi di sistema, cartelle utente di primo livello, radici dei volumi, credenziali (.ssh, .gnupg, .aws, Keychains) e versioni attive di nvm/pyenv/rustup/fnm. Massimo 50 percorsi. Annullabile con restore_last. Usa prima plan_cleanup o gli strumenti di analisi e non proporre percorsi non verificati.",
            properties: ["paths": ["type": "array", "items": ["type": "string"], "description": "Percorsi assoluti da spostare nel Cestino."] as JSON,
                         "reason": prop("string", "Perché si propone la pulizia (mostrato all'utente, max 200 caratteri).")],
            required: ["paths"], readOnly: false, destructive: true, handler: toolTrashPaths),
    MCPTool(name: "restore_last",
            description: "Annulla l'ultima pulizia registrata (anche fatta dall'app): rimette gli elementi nel percorso originale se sono ancora nel Cestino e il percorso è libero.",
            properties: [:], required: [], readOnly: false, destructive: false, handler: toolRestoreLast),
]

// MARK: - Protocollo JSON-RPC

private let writeLock = NSLock()

private func send(_ obj: JSON) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    writeLock.lock()
    FileHandle.standardOutput.write(d + Data("\n".utf8))
    writeLock.unlock()
}

private func reply(_ id: Any, result: Any) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
private func replyError(_ id: Any, code: Int, _ msg: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg] as JSON]) }

private let serverInstructions = """
DetectHugeFile analizza l'uso del disco su macOS e aiuta a recuperare spazio in sicurezza.
Flusso consigliato: list_volumes / scan_folders per capire dove sta lo spazio; find_artifacts, find_duplicates, known_offenders, \
containers_summary, brew_summary per i dettagli; plan_cleanup per un piano; trash_paths solo per eseguire ciò che l'utente ha scelto.
Le scansioni grandi possono richiedere circa un minuto. Gli strumenti di analisi non modificano nulla. trash_paths sposta nel Cestino \
dopo una conferma dell'utente in una finestra di sistema; se rifiutata, non insistere. Se compaiono 'access_denied', manca l'Accesso \
completo al disco per il processo che ha avviato il server.
"""

func handleMessage(_ msg: JSON) {
    let method = msg["method"] as? String ?? ""
    let id = msg["id"]
    guard let id else { return }                              // notifiche (initialized, cancelled…): nessuna risposta
    let params = msg["params"] as? JSON ?? [:]

    switch method {
    case "initialize":
        let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
        let req = params["protocolVersion"] as? String ?? ""
        reply(id, result: ["protocolVersion": supported.contains(req) ? req : supported[0],
                           "capabilities": ["tools": ["listChanged": false] as JSON] as JSON,
                           "serverInfo": ["name": "detecthugefile", "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"] as JSON,
                           "instructions": serverInstructions] as JSON)
    case "ping":
        reply(id, result: [:] as JSON)
    case "tools/list":
        reply(id, result: ["tools": mcpTools.map(\.definition)] as JSON)
    case "tools/call":
        guard let name = params["name"] as? String, let tool = mcpTools.first(where: { $0.name == name }) else {
            replyError(id, code: -32602, "Strumento sconosciuto"); return
        }
        let args = params["arguments"] as? JSON ?? [:]
        log("call \(name)")
        do {
            let result = try tool.handler(args)
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            reply(id, result: ["content": [["type": "text", "text": String(data: data, encoding: .utf8) ?? "{}"] as JSON], "isError": false] as JSON)
        } catch let e as ToolError {
            reply(id, result: ["content": [["type": "text", "text": e.message] as JSON], "isError": true] as JSON)
        } catch {
            reply(id, result: ["content": [["type": "text", "text": error.localizedDescription] as JSON], "isError": true] as JSON)
        }
    default:
        replyError(id, code: -32601, "Metodo non supportato: \(method)")
    }
}

/// Avvia il server: legge richieste da stdin (una per riga) sul thread di lavoro; il main thread resta libero per gli scanner.
func runMCPServer() -> Never {
    log("avviato (\(mcpTools.count) strumenti)")
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let d = t.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? JSON else {
                if !t.isEmpty { log("messaggio non valido ignorato") }
                continue
            }
            handleMessage(obj)
        }
        log("stdin chiuso, uscita")
        exit(0)
    }
    dispatchMain()
}
