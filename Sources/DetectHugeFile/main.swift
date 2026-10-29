import Foundation
import SwiftUI

// Modalità CLI di debug/benchmark:  DetectHugeFile --scan PATH [--top N]
if CommandLine.arguments.contains("--check") {
    var gb = 1.0
    if let i = CommandLine.arguments.firstIndex(of: "--min-gb"), i + 1 < CommandLine.arguments.count { gb = Double(CommandLine.arguments[i + 1]) ?? 1 }
    Reminder.runCheck(minGB: gb, notify: !CommandLine.arguments.contains("--no-notify"))
}
if let i = CommandLine.arguments.firstIndex(of: "--dups"), i + 1 < CommandLine.arguments.count {
    let root = CommandLine.arguments[i + 1]
    Task { @MainActor in
        let m = DuplicatesModel()
        m.rootPath = root
        m.minMB = 1
        m.scan()
        while m.scanning { try? await Task.sleep(nanoseconds: 200_000_000) }
        print("Gruppi: \(m.groups.count) · spreco \(formatBytes(m.wasted))")
        for g in m.groups { print("  \(g.files.count) × \(formatBytes(g.size)): " + g.files.map { ($0.id as NSString).lastPathComponent }.sorted().joined(separator: ", ")) }
        exit(0)
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--treemap-test") {
    let vals: [Double] = [6, 6, 4, 3, 2, 2, 1]
    let rs = squarify(vals, in: CGRect(x: 0, y: 0, width: 600, height: 400))
    let area = rs.reduce(0) { $0 + Double($1.width * $1.height) }
    let inside = rs.allSatisfy { CGRect(x: -0.01, y: -0.01, width: 600.02, height: 400.02).contains($0) }
    print("area totale \(area) (attesa 240000) · tutti dentro: \(inside)")
    var overlap = false
    for a in 0..<rs.count { for b in (a + 1)..<rs.count where rs[a].insetBy(dx: 0.01, dy: 0.01).intersects(rs[b]) { overlap = true } }
    print("sovrapposizioni: \(overlap)")
    exit(0)
}
if CommandLine.arguments.contains("--containers") {
    var podmanIDs: Set<String> = []
    for (n, b) in [("podman", findBinary("podman")), ("docker", findBinary("docker"))] {
        guard let b else { print("\(n): non installato"); continue }
        var (e, items, ids) = loadEngine(n, b)
        if n == "podman" { podmanIDs = ids } else if !ids.isDisjoint(with: podmanIDs) { print("docker: alias di podman (stesso socket) → ignorato"); items = [] }
        print("== \(n) \(e.version) \(e.error ?? "")")
        for s in e.summary { print("   \(s.label): totale \(s.total), \(s.size), recuperabili \(s.reclaim)") }
        for sec in CSection.allCases {
            let r = items.filter { $0.section == sec }
            if r.isEmpty { continue }
            print("   [\(sec.rawValue)] \(r.count) · \(formatBytes(r.reduce(0) { $0 + ($1.size ?? 0) }))")
            for it in r.sorted(by: { ($0.size ?? 0) > ($1.size ?? 0) }).prefix(4) { print("      \(it.size.map(formatBytes) ?? "—")  \(it.title)  [\(it.inUse ? "in uso" : "libero")\(it.minikube ? ", minikube" : "")]") }
        }
    }
    let vols: [String: UInt64] = [:]
    for it in loadMinikube(volumesByName: vols) { print("minikube: \(it.title) — \(it.subtitle.prefix(90))") }
    if let vm = podmanVMDisk() { print("VM podman: occupa \(formatBytes(vm.allocated)) (logico \(formatBytes(vm.logical)))") }
    exit(0)
}
if CommandLine.arguments.contains("--brew") {
    guard let b = brewBinary() else { print("brew non trovato"); exit(0) }
    let items = parseBrewInfo(brewRun(b, ["info", "--json=v2", "--installed"], timeout: 120).out)
    let leaves = items.filter { !$0.isCask && $0.leaf }, deps = items.filter { !$0.isCask && !$0.leaf }, casks = items.filter { $0.isCask }
    print("formule: \(items.count - casks.count) (installate da te: \(leaves.count), dipendenze: \(deps.count)) · cask: \(casks.count)")
    let brewLeaves = Set(brewRun(b, ["leaves"], timeout: 30).out.split(separator: "\n").map(String.init))
    let unused = Set(items.filter { !$0.isCask && $0.usedBy.isEmpty }.map(\.name))
    print("`brew leaves`: \(brewLeaves.count) · formule non richieste da altre (mio calcolo): \(unused.count) · coincidono: \(unused == brewLeaves)")
    if unused != brewLeaves { print("   solo mie:", unused.subtracting(brewLeaves).sorted().prefix(8), " solo brew:", brewLeaves.subtracting(unused).sorted().prefix(8)) }
    let both = leaves.filter { !$0.usedBy.isEmpty }
    print("installate da te MA anche richieste da altre (bloccate): \(both.count) → es. \(both.prefix(3).map(\.name))")
    print("cask con app:", casks.filter { !$0.apps.isEmpty }.map { "\($0.name)→\($0.apps)" }.prefix(3))
    print("esempio bloccata (usata da altri):", items.first(where: { !$0.usedBy.isEmpty }).map { "\($0.name) ← \($0.usedBy.prefix(3))" } ?? "-")
    print("esempio cask:", casks.first.map { "\($0.name) \($0.version) app=\($0.apps)" } ?? "-")
    exit(0)
}
if CommandLine.arguments.contains("--known") {
    for it in knownItems where FileManager.default.fileExists(atPath: it.path) {
        let sem = DispatchSemaphore(value: 0)
        let sc = Scanner(path: it.path)
        sc.onFinish = { sem.signal() }
        sc.start()
        // onFinish è consegnato sul main: giriamo il runloop finché non arriva
        while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        print(String(format: "%12@  %@%@", formatBytes(sc.root.size), it.title, sc.root.denied ? "  (negato)" : ""))
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--artifacts"), i + 1 < CommandLine.arguments.count {
    let t0 = Date()
    let home = NSHomeDirectory()
    let sc = Scanner(path: CommandLine.arguments[i + 1], extraSkip: [home + "/Library", home + "/.Trash"])
    sc.onFinish = {
        let rows = findArtifacts(root: sc.root).sorted { $0.size > $1.size }
        print(String(format: "Scansione+analisi: %.2fs  artefatti: %d  totale: %@", Date().timeIntervalSince(t0), rows.count, formatBytes(rows.reduce(0) { $0 + $1.size })))
        for e in Eco.allCases { let r = rows.filter { $0.eco == e }; print("  \(e.rawValue): \(r.count) · \(formatBytes(r.reduce(0) { $0 + $1.size }))") }
        for r in rows.prefix(15) { print("\(r.eco.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(formatBytes(r.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.id)") }
        exit(0)
    }
    sc.start()
    dispatchMain()
}
if let i = CommandLine.arguments.firstIndex(of: "--scan"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    var top = 15
    if let t = CommandLine.arguments.firstIndex(of: "--top"), t + 1 < CommandLine.arguments.count { top = Int(CommandLine.arguments[t + 1]) ?? 15 }
    let t0 = Date()
    let sc = Scanner(path: path)
    sc.onFinish = {
        var all: [Node] = []
        var stack = [sc.root]
        while let n = stack.popLast() { all.append(n); stack.append(contentsOf: n.children.filter { $0.isDir }) }
        let s = sc.stats
        print(String(format: "Scansione: %.2fs  cartelle: %d  file: %d  totale: %@ (%llu byte)", Date().timeIntervalSince(t0), all.count, s.files, formatBytes(sc.root.size), sc.root.size))
        for n in all.sorted(by: { $0.size > $1.size }).prefix(top) { print(String(format: "%12llu  %@", n.size, n.path)) }
        exit(0)
    }
    sc.start()
    dispatchMain()
} else {
    DetectHugeFileApp.main()
}
