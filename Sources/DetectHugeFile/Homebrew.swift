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

struct BItem: Identifiable {
    let id: String
    let isCask: Bool
    let name: String
    let version: String
    let desc: String
    let leaf: Bool              // installata esplicitamente (formule); i cask sono sempre "tue"
    let usedBy: [String]        // formule installate che dipendono da questa
    var size: UInt64 = 0
    var apps: [String] = []     // cask: app in /Applications

    var kind: String { isCask ? "Cask" : (leaf ? "Formula" : "Dipendenza") }
    var kindSort: String { kind }
    var removable: Bool { usedBy.isEmpty }
    var state: String {
        if isCask { return "app" }
        if !usedBy.isEmpty { return "richiesta da: " + usedBy.prefix(3).joined(separator: ", ") + (usedBy.count > 3 ? " +\(usedBy.count - 3)" : "") }
        return leaf ? "installata da te" : "dipendenza orfana"
    }
}

func brewBinary() -> String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }

/// `brew` senza aggiornamenti automatici (lenti e invasivi) né pulizie implicite.
func brewRun(_ bin: String, _ args: [String], timeout: TimeInterval = 120) -> (status: Int32, out: String) {
    shell("/usr/bin/env", ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_ANALYTICS=1", bin] + args, timeout: timeout)
}

func parseBrewInfo(_ json: String) -> [BItem] {
    guard let d = json.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
    let formulae = j["formulae"] as? [[String: Any]] ?? []
    let casks = j["casks"] as? [[String: Any]] ?? []

    // dipendenze inverse fra le sole formule installate
    var usedBy: [String: [String]] = [:]
    for f in formulae {
        guard let n = f["name"] as? String, let inst = (f["installed"] as? [[String: Any]])?.last else { continue }
        for dep in (inst["runtime_dependencies"] as? [[String: Any]] ?? []) {
            if let dn = dep["full_name"] as? String { usedBy[dn.components(separatedBy: "/").last ?? dn, default: []].append(n) }
        }
    }
    var out: [BItem] = []
    for f in formulae {
        guard let n = f["name"] as? String else { continue }
        let inst = (f["installed"] as? [[String: Any]])?.last
        out.append(BItem(id: "f:" + n, isCask: false, name: n, version: inst?["version"] as? String ?? "",
                         desc: f["desc"] as? String ?? "", leaf: (inst?["installed_on_request"] as? Bool) ?? false,
                         usedBy: (usedBy[n] ?? []).sorted()))
    }
    for c in casks {
        guard let t = c["token"] as? String else { continue }
        var apps: [String] = []
        for a in (c["artifacts"] as? [[String: Any]] ?? []) {
            for app in (a["app"] as? [Any] ?? []) { if let s = app as? String { apps.append((s as NSString).lastPathComponent) } }
        }
        out.append(BItem(id: "c:" + t, isCask: true, name: t, version: c["installed"] as? String ?? "",
                         desc: c["desc"] as? String ?? "", leaf: true, usedBy: [], apps: apps))
    }
    return out
}

@MainActor
final class BrewModel: ObservableObject {
    @Published var items: [BItem] = []
    @Published var selection: Set<String> = []
    @Published var loading = false
    @Published var busy = false
    @Published var status = ""
    @Published var filter = 0       // 0 tutti, 1 installate da me, 2 dipendenze, 3 cask
    @Published var search = ""
    @Published var cacheSize: UInt64 = 0
    @Published var cleanupEstimate = ""
    @Published var autoremoveList: [String] = []
    @Published var missing = false
    private var started = false
    private var bin: String?
    private let measurer = SizeMeasurer()

    func loadIfNeeded() { if !started { load() } }

    func load() {
        started = true
        guard let b = brewBinary() else { missing = true; return }
        bin = b
        loading = true; selection = []
        status = "Lettura di Homebrew…"
        DispatchQueue.global(qos: .userInitiated).async {
            let info = brewRun(b, ["info", "--json=v2", "--installed"], timeout: 120)
            let items = parseBrewInfo(info.out)
            let prefix = brewRun(b, ["--prefix"], timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let cache = brewRun(b, ["--cache"], timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanup = brewRun(b, ["cleanup", "-n", "-s", "--prune=all"], timeout: 60).out
            let auto = brewRun(b, ["autoremove", "-n"], timeout: 60).out
            DispatchQueue.main.async { [self] in
                self.items = items.sorted { $0.name < $1.name }
                self.loading = false
                self.cleanupEstimate = cleanup.split(separator: "\n").last(where: { $0.contains("free approximately") }).map(String.init) ?? ""
                var names: [String] = []
                var capture = false
                for l in auto.split(separator: "\n") {
                    if l.contains("Would autoremove") { capture = true; continue }
                    if capture, !l.hasPrefix("==>"), !l.isEmpty { names.append(String(l)) }
                }
                self.autoremoveList = names
                self.status = "\(items.count) pacchetti"
                self.measure(prefix: prefix, cache: cache)
            }
        }
    }

    private func measure(prefix: String, cache: String) {
        func assign(_ root: Node, cask: Bool) {
            let sizes = Dictionary(root.children.map { ($0.name, $0.size) }, uniquingKeysWith: max)
            for i in items.indices where items[i].isCask == cask { items[i].size += sizes[items[i].name] ?? 0 }
        }
        let cellar = Scanner(path: prefix + "/Cellar")
        cellar.onFinish = { [weak self] in self?.assignFromScan(cellar, cask: false); cellar.onFinish = nil }
        cellar.start()
        let caskroom = Scanner(path: prefix + "/Caskroom")
        caskroom.onFinish = { [weak self] in
            self?.assignFromScan(caskroom, cask: true); caskroom.onFinish = nil
            // le app dei cask stanno in /Applications
            guard let self else { return }
            for it in self.items where it.isCask {
                for app in it.apps {
                    let p = "/Applications/" + app
                    if FileManager.default.fileExists(atPath: p) {
                        self.measurer.add(p) { [weak self] size, _ in
                            guard let self, let i = self.items.firstIndex(where: { $0.id == it.id }) else { return }
                            self.items[i].size += size
                        }
                    }
                }
            }
        }
        caskroom.start()
        if FileManager.default.fileExists(atPath: cache) {
            measurer.add(cache) { [weak self] size, _ in self?.cacheSize = size }
        }
    }

    private func assignFromScan(_ sc: Scanner, cask: Bool) {
        let sizes = Dictionary(sc.root.children.map { ($0.name, $0.size) }, uniquingKeysWith: max)
        for i in items.indices where items[i].isCask == cask { items[i].size += sizes[items[i].name] ?? 0 }
    }

    func filtered(_ order: [KeyPathComparator<BItem>]) -> [BItem] {
        let q = search.lowercased()
        return items.filter {
            switch filter {
            case 1: if $0.isCask || !$0.leaf { return false }
            case 2: if $0.isCask || $0.leaf { return false }
            case 3: if !$0.isCask { return false }
            default: break
            }
            return q.isEmpty || $0.name.lowercased().contains(q) || $0.desc.lowercased().contains(q)
        }.sorted(using: order)
    }

    func exportTable() -> ExportTable {
        ExportTable(headers: ["Nome", "Tipo", "Versione", "Byte", "Dimensione", "Stato", "Descrizione"],
                    rows: items.sorted { $0.size > $1.size }.map { [$0.name, $0.kind, $0.version, String($0.size), formatBytes($0.size), $0.state, $0.desc] })
    }

    // MARK: azioni

    func uninstallSelected() {
        guard let bin, !busy else { return }
        let sel = items.filter { selection.contains($0.id) && $0.removable }
        guard !sel.isEmpty else { return }
        let total = sel.reduce(0) { $0 + $1.size }
        if dryRunReport(count: sel.count, bytes: total, detail: sel.prefix(10).map { "• brew uninstall \($0.name)" }.joined(separator: "\n")) { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Disinstallare \(sel.count) pacchetti?"
        a.informativeText = sel.prefix(10).map { "• \($0.kind) \($0.name) — \(formatBytes($0.size))" }.joined(separator: "\n") +
            (sel.count > 10 ? "\n… e altri \(sel.count - 10)" : "") +
            "\n\nTotale: \(formatBytes(total)). Non passa dal Cestino: per reinstallare serve `brew install`." +
            (sel.contains { $0.isCask } ? "\nI cask rimuovono anche l'app da /Applications." : "")
        a.addButton(withTitle: "Disinstalla"); a.addButton(withTitle: "Annulla")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(label: "Disinstallazione") {
            sel.compactMap { it in
                let r = brewRun(bin, ["uninstall", it.isCask ? "--cask" : "--formula", it.name], timeout: 300)
                return r.status == 0 ? nil : "\(it.name): \(r.out.split(separator: "\n").last.map { String($0.prefix(100)) } ?? "errore")"
            }
        }
    }

    func cleanup() {
        guard let bin, !busy else { return }
        if dryRunReport(count: 0, bytes: 0, detail: "brew cleanup -s --prune=all\n\(cleanupEstimate)") { return }
        let a = NSAlert()
        a.messageText = "Eseguire brew cleanup?"
        a.informativeText = "Rimuove vecchie versioni, cache scaricate e file obsoleti.\n\(cleanupEstimate)"
        a.addButton(withTitle: "Esegui"); a.addButton(withTitle: "Annulla")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(label: "Cleanup") {
            let r = brewRun(bin, ["cleanup", "-s", "--prune=all"], timeout: 600)
            return r.status == 0 ? [] : [String(r.out.suffix(200))]
        }
    }

    func autoremove() {
        guard let bin, !busy, !autoremoveList.isEmpty else { return }
        if dryRunReport(count: autoremoveList.count, bytes: 0, detail: autoremoveList.joined(separator: ", ")) { return }
        let a = NSAlert()
        a.messageText = "Rimuovere \(autoremoveList.count) dipendenze orfane?"
        a.informativeText = "Formule installate come dipendenza e non più richieste da nulla:\n" + autoremoveList.prefix(15).joined(separator: ", ")
        a.addButton(withTitle: "Rimuovi"); a.addButton(withTitle: "Annulla")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(label: "Autoremove") {
            let r = brewRun(bin, ["autoremove"], timeout: 600)
            return r.status == 0 ? [] : [String(r.out.suffix(200))]
        }
    }

    private func run(label: String, _ job: @escaping () -> [String]) {
        busy = true; status = "\(label) in corso…"
        DispatchQueue.global(qos: .userInitiated).async {
            let errs = job()
            DispatchQueue.main.async { [self] in
                busy = false
                load()
                status = "\(label) completata" + (errs.isEmpty ? "" : " · \(errs.count) errori")
                if !errs.isEmpty {
                    let e = NSAlert(); e.messageText = "Alcune operazioni non sono riuscite"
                    e.informativeText = errs.prefix(6).joined(separator: "\n"); e.runModal()
                }
            }
        }
    }
}

struct HomebrewView: View {
    @ObservedObject var brew: BrewModel
    @State private var order = [KeyPathComparator(\BItem.size, order: .reverse)]

    var body: some View {
        let rows = brew.filtered(order)
        VStack(spacing: 0) {
            if brew.missing {
                Text("Homebrew non trovato in /opt/homebrew o /usr/local.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                ZStack {
                    Table(rows, selection: $brew.selection, sortOrder: $order) {
                        TableColumn("Nome", value: \.name) { r in
                            HStack(spacing: 4) {
                                if !r.removable { Image(systemName: "lock.fill").foregroundStyle(.orange).help("Richiesta da altre formule") }
                                Text(r.name).fontWeight(.medium)
                            }
                        }.width(min: 140, ideal: 200)
                        TableColumn("Tipo", value: \.kindSort) { r in
                            Text(r.kind).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                .background((r.isCask ? Color.purple : r.leaf ? Color.green : Color.gray).opacity(0.2), in: Capsule())
                        }.width(min: 90, ideal: 100)
                        TableColumn("Versione", value: \.version) { r in Text(r.version).foregroundStyle(.secondary) }.width(min: 70, ideal: 90)
                        TableColumn("Dimensione", value: \.size) { r in
                            Text(formatBytes(r.size)).font(.system(.body, design: .monospaced).weight(.semibold))
                                .foregroundStyle(r.size > 1 << 30 ? Color.orange : Color.primary)
                        }.width(min: 90, ideal: 100)
                        TableColumn("Stato") { r in Text(r.state).foregroundStyle(.secondary).lineLimit(1) }.width(min: 140, ideal: 200)
                        TableColumn("Descrizione") { r in Text(r.desc).foregroundStyle(.secondary).lineLimit(1).help(r.desc) }
                    }
                    if brew.loading { ProgressView("Lettura di Homebrew…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                if brew.selection.isEmpty { Text(brew.status) } else {
                    let t = brew.items.filter { brew.selection.contains($0.id) }.reduce(0) { $0 + $1.size }
                    Text("\(brew.selection.count) selezionati · \(formatBytes(t))").fontWeight(.medium)
                }
                Spacer()
                Text("Visibili: \(formatBytes(rows.reduce(0) { $0 + $1.size }))")
            }
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear { brew.loadIfNeeded() }
        .searchable(text: $brew.search, placement: .toolbar, prompt: "Cerca pacchetto")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { brew.load() } label: { Label("Rianalizza", systemImage: "arrow.clockwise") }
                Button { brew.cleanup() } label: { Label("Cleanup", systemImage: "sparkles") }
                    .help("brew cleanup -s --prune=all  \(brew.cleanupEstimate)")
                Button { brew.autoremove() } label: { Label("Autoremove", systemImage: "wand.and.stars") }
                    .disabled(brew.autoremoveList.isEmpty).help("Rimuove le dipendenze non più necessarie")
                Button(role: .destructive) { brew.uninstallSelected() } label: { Label("Disinstalla", systemImage: "trash") }
                    .disabled(brew.selection.isEmpty || brew.busy)
                GlobalToolbarButtons()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("", selection: $brew.filter) {
                Text("Tutti").tag(0); Text("Installate da te").tag(1); Text("Dipendenze").tag(2); Text("Cask").tag(3)
            }.pickerStyle(.segmented).frame(width: 380).labelsHidden()
            Spacer()
            if brew.cacheSize > 0 { Text("Cache: \(formatBytes(brew.cacheSize))").foregroundStyle(.secondary) }
            if !brew.cleanupEstimate.isEmpty {
                Text(brew.cleanupEstimate.replacingOccurrences(of: "This operation would free approximately ", with: "Cleanup libera ≈ ").replacingOccurrences(of: " of disk space.", with: ""))
                    .foregroundStyle(.green).fontWeight(.medium)
            }
            if !brew.autoremoveList.isEmpty { Text("\(brew.autoremoveList.count) dipendenze orfane").foregroundStyle(.orange).fontWeight(.medium) }
        }
        .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
    }
}
