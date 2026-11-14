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

// MARK: - Modello dati

enum CSection: String, CaseIterable {
    case vm = "Disco della VM Podman", container = "Container", image = "Immagini", volume = "Volumi", minikube = "minikube"
}

struct CItem: Identifiable {
    let id: String
    let section: CSection
    let engine: String          // podman | docker | minikube
    let title: String
    let subtitle: String
    var size: UInt64?
    var inUse = false
    var minikube = false
    var danger = false          // dati persistenti (volumi) o in esecuzione
    var command: [String]?      // eseguibile + argomenti per la rimozione
    var trashPath: String?      // oppure: sposta nel Cestino
    var removable: Bool { command != nil || trashPath != nil }
}

struct EngineInfo: Identifiable {
    var id: String { name }
    let name: String
    let bin: String
    var version = ""
    var error: String?
    var note: String?
    var summary: [(label: String, total: String, size: String, reclaim: String)] = []
}

// MARK: - Utilità di parsing

func findBinary(_ name: String) -> String? {
    ["/opt/podman/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin"]
        .map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Podman stampa un array JSON, Docker un oggetto per riga: gestisce entrambi.
func parseJSONObjects(_ text: String) -> [[String: Any]] {
    guard let d = text.data(using: .utf8) else { return [] }
    if let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { return a }
    if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return [o] }
    return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

/// "32.96GB", "23.39kB", "1.5 GiB", "0B" → byte
func parseSize(_ s: String) -> UInt64? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let digits = t.prefix { "0123456789.".contains($0) }
    guard let v = Double(digits) else { return nil }
    let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
    let mult: Double
    switch unit {
    case "", "b": mult = 1
    case "kb": mult = 1e3
    case "mb": mult = 1e6
    case "gb": mult = 1e9
    case "tb": mult = 1e12
    case "kib": mult = 1024
    case "mib": mult = 1_048_576
    case "gib": mult = 1_073_741_824
    case "tib": mult = 1_099_511_627_776
    default: return nil
    }
    return UInt64(v * mult)
}

private func nameString(_ v: Any?) -> String {
    if let a = v as? [String] { return a.joined(separator: ", ") }
    if let s = v as? String { return s }
    return ""
}

private func sizeValue(_ v: Any?) -> UInt64? {
    if let n = v as? NSNumber { return n.uint64Value }
    if let s = v as? String { return parseSize(s) }
    return nil
}

/// Tabelle testuali di `system df -v`: righe della sezione dei volumi → [nome: (byte, link)].
func parseVolumeTable(_ text: String) -> [String: (UInt64, Int)] {
    var out: [String: (UInt64, Int)] = [:]
    var inSection = false, sawHeader = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let l = String(line)
        if l.contains("Volumes space usage") { inSection = true; sawHeader = false; continue }
        guard inSection else { continue }
        if l.trimmingCharacters(in: .whitespaces).isEmpty { if sawHeader { break }; continue }
        if !sawHeader { sawHeader = true; continue }       // intestazione colonne
        let t = l.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard t.count >= 3, let size = parseSize(t[t.count - 1]) else { continue }
        out[t[0]] = (size, Int(t[t.count - 2]) ?? 0)
    }
    return out
}

func parseDFSummary(_ text: String) -> [(label: String, total: String, size: String, reclaim: String)] {
    var rows: [(String, String, String, String)] = []
    for l in text.split(separator: "\n") {
        for label in ["Images", "Containers", "Local Volumes", "Build Cache"] where l.hasPrefix(label) {
            let t = l.dropFirst(label.count).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if t.count >= 4 { rows.append((label, t[0], t[2], t[3])) }
        }
    }
    return rows
}

// MARK: - Caricamento (thread di background)

struct ContainerSnapshot {
    var engines: [EngineInfo] = []
    var items: [CItem] = []
}

func loadEngine(_ name: String, _ bin: String) -> (EngineInfo, [CItem], Set<String>) {
    var info = EngineInfo(name: name, bin: bin)
    info.version = shell(bin, ["--version"], timeout: 10).out.split(separator: "\n").first.map(String.init) ?? ""
    let ps = shell(bin, ["ps", "-a", "--format", "json"], timeout: 25)
    guard ps.status == 0 else {
        let msg = ps.out.split(separator: "\n").first.map(String.init) ?? "non raggiungibile"
        info.error = name == "podman" ? "Podman non risponde (machine spenta? prova `podman machine start`) — \(msg.prefix(90))" : "Il demone Docker non risponde — \(msg.prefix(90))"
        return (info, [], [])
    }
    let containers = parseJSONObjects(ps.out)
    let images = parseJSONObjects(shell(bin, ["images", "--format", "json"], timeout: 30).out)
    let vols = parseJSONObjects(shell(bin, ["volume", "ls", "--format", "json"], timeout: 30).out)
    let dfv = shell(bin, ["system", "df", "-v"], timeout: 60).out
    info.summary = parseDFSummary(shell(bin, ["system", "df"], timeout: 30).out)
    let volSizes = parseVolumeTable(dfv)

    var items: [CItem] = []
    var imageIDs: Set<String> = []
    var imageRefs: Set<String> = []
    var minikubeNames: Set<String> = []

    for c in containers {
        let id = (c["Id"] ?? c["ID"]) as? String ?? ""
        let names = nameString(c["Names"])
        let image = c["Image"] as? String ?? ""
        let state = (c["State"] as? String ?? "").lowercased()
        let running = state == "running"
        let labels = String(describing: c["Labels"] ?? "")
        let mk = labels.contains("minikube") || names.contains("minikube")
        if mk { minikubeNames.insert(names) }
        imageRefs.insert(image.lowercased())
        if let iid = c["ImageID"] as? String { imageRefs.insert(String(iid.prefix(12))) }
        items.append(CItem(id: "\(name):c:\(id)", section: .container, engine: name, title: names.isEmpty ? String(id.prefix(12)) : names,
                           subtitle: "\(image) · \(c["Status"] as? String ?? state)", size: nil, inUse: running, minikube: mk, danger: running,
                           command: [bin, "rm", "-f", id]))
    }
    for im in images {
        let id = (im["Id"] ?? im["ID"]) as? String ?? ""
        imageIDs.insert(String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)))
        let repo = im["Repository"] as? String ?? "<none>"
        let tag = im["Tag"] as? String ?? "<none>"
        let title = repo == "<none>" ? "<senza nome> \(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))" : "\(repo):\(tag)"
        let n = (im["Containers"] as? NSNumber)?.intValue ?? 0
        let used = n > 0 || imageRefs.contains(title.lowercased()) || imageRefs.contains(String(id.prefix(12)))
        let created = (im["CreatedSince"] as? String) ?? String(((im["CreatedAt"] as? String) ?? "").prefix(10))
        let sub = [created, used ? "in uso da un container" : (repo == "<none>" ? "orfana (dangling)" : "non usata")].filter { !$0.isEmpty }.joined(separator: " · ")
        items.append(CItem(id: "\(name):i:\(id)", section: .image, engine: name, title: title, subtitle: sub, size: sizeValue(im["Size"]),
                           inUse: used, minikube: title.contains("minikube") || title.contains("kicbase"), command: [bin, "rmi", id]))
    }
    for v in vols {
        guard let vn = v["Name"] as? String else { continue }
        let (size, links) = volSizes[vn] ?? (0, (v["MountCount"] as? NSNumber)?.intValue ?? 0)
        let mk = minikubeNames.contains(vn) || vn.contains("minikube")
        items.append(CItem(id: "\(name):v:\(vn)", section: .volume, engine: name, title: vn,
                           subtitle: links > 0 ? "usato da \(links) container · contiene dati persistenti" : "non usato · contiene dati persistenti",
                           size: volSizes[vn]?.0, inUse: links > 0, minikube: mk, danger: true, command: [bin, "volume", "rm", vn]))
        _ = size
    }
    return (info, items, imageIDs)
}

func loadMinikube(volumesByName: [String: UInt64]) -> [CItem] {
    guard let mk = findBinary("minikube") else { return [] }
    let home = NSHomeDirectory()
    var items: [CItem] = []
    let r = shell(mk, ["profile", "list", "-o", "json"], timeout: 20)
    if let d = r.out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        for p in (j["valid"] as? [[String: Any]] ?? []) + (j["invalid"] as? [[String: Any]] ?? []) {
            guard let name = p["Name"] as? String else { continue }
            let cfg = p["Config"] as? [String: Any]
            let driver = cfg?["Driver"] as? String ?? "?"
            let status = p["Status"] as? String ?? "?"
            items.append(CItem(id: "mk:p:\(name)", section: .minikube, engine: "minikube", title: "Profilo “\(name)”",
                               subtitle: "driver \(driver) · stato \(status) · `minikube delete -p \(name)` rimuove cluster e volume",
                               size: volumesByName[name], inUse: status.lowercased() == "running", minikube: true, danger: true,
                               command: [mk, "delete", "-p", name]))
        }
    }
    let cache = home + "/.minikube/cache"
    if FileManager.default.fileExists(atPath: cache) {
        items.append(CItem(id: "mk:cache", section: .minikube, engine: "minikube", title: "Cache minikube (ISO, immagini, binari)",
                           subtitle: "~/.minikube/cache · si riscarica al prossimo `minikube start`", size: nil, minikube: true, trashPath: cache))
    }
    return items
}

/// Immagine disco della VM di Podman: dimensione realmente occupata sul Mac (file sparso).
func podmanVMDisk() -> (path: String, allocated: UInt64, logical: UInt64)? {
    let base = NSHomeDirectory() + "/.local/share/containers/podman/machine"
    guard let en = FileManager.default.enumerator(atPath: base) else { return nil }
    for case let rel as String in en where rel.hasSuffix(".raw") || rel.hasSuffix(".qcow2") {
        var st = stat()
        if stat(base + "/" + rel, &st) == 0 { return (base + "/" + rel, UInt64(st.st_blocks) * 512, UInt64(st.st_size)) }
    }
    return nil
}

// MARK: - Modello UI

@MainActor
final class ContainersModel: ObservableObject {
    @Published var items: [CItem] = []
    @Published var engines: [EngineInfo] = []
    @Published var selection: Set<String> = []
    @Published var loading = false
    @Published var busy = false
    @Published var status = ""
    @Published var vmDisk: (path: String, allocated: UInt64, logical: UInt64)?
    private var started = false
    private let measurer = SizeMeasurer()

    func loadIfNeeded() { if !started { load() } }

    func load() {
        started = true
        loading = true; selection = []
        measurer.cancel()
        DispatchQueue.global(qos: .userInitiated).async {
            var engines: [EngineInfo] = [], items: [CItem] = []
            var podmanIDs: Set<String> = []
            if let p = findBinary("podman") {
                let (e, it, ids) = loadEngine("podman", p)
                engines.append(e); items += it; podmanIDs = ids
            }
            if let d = findBinary("docker") {
                var (e, it, ids) = loadEngine("docker", d)
                if !podmanIDs.isEmpty && !ids.isDisjoint(with: podmanIDs) {
                    // /var/run/docker.sock → socket di Podman: stessi dati, non duplicare
                    e.note = "Il CLI docker è collegato a Podman (stesso socket): voci già mostrate sotto Podman."
                    it = []
                }
                engines.append(e); items += it
            } else if engines.isEmpty == false {
                // nessun Docker: nessuna voce
            }
            let vols = Dictionary(items.filter { $0.section == .volume }.map { ($0.title, $0.size ?? 0) }, uniquingKeysWith: max)
            items += loadMinikube(volumesByName: vols)
            let vm = podmanVMDisk()
            DispatchQueue.main.async { [self] in
                self.engines = engines
                self.vmDisk = vm
                var all = items
                if let vm {
                    all.insert(CItem(id: "podman:vm", section: .vm, engine: "podman", title: "Disco della macchina virtuale Podman",
                                     subtitle: "\(abbreviate(vm.path)) · dimensione logica \(formatBytes(vm.logical)), occupa davvero \(formatBytes(vm.allocated)) sul Mac. Non si restringe da solo: dopo la pulizia usa “Compatta disco VM”.",
                                     size: vm.allocated), at: 0)
                }
                self.items = all
                self.loading = false
                self.status = "\(items.count) elementi"
                // dimensioni cache minikube
                for it in all where it.trashPath != nil {
                    measurer.add(it.trashPath!) { [weak self] size, _ in
                        guard let self, let i = self.items.firstIndex(where: { $0.id == it.id }) else { return }
                        self.items[i].size = size
                    }
                }
            }
        }
    }

    func exportTable() -> ExportTable {
        ExportTable(headers: ["Sezione", "Motore", "Nome", "Dettagli", "Byte", "Dimensione", "In uso"],
                    rows: items.map { [$0.section.rawValue, $0.engine, $0.title, $0.subtitle, String($0.size ?? 0), $0.size.map(formatBytes) ?? "", $0.inUse ? "sì" : "no"] })
    }

    private func reclaim(_ e: EngineInfo, _ label: String) -> String {
        e.summary.first { $0.label == label }.map { "recuperabili \($0.reclaim)" } ?? ""
    }

    // MARK: azioni

    func deleteSelected() {
        let sel = items.filter { selection.contains($0.id) && $0.removable }
        guard !sel.isEmpty, !busy else { return }
        let total = sel.reduce(0) { $0 + ($1.size ?? 0) }
        if dryRunReport(count: sel.count, bytes: total, detail: sel.prefix(10).map { "• \($0.section.rawValue): \($0.title)" }.joined(separator: "\n")) { return }
        let danger = sel.filter { $0.danger || $0.inUse }
        let a = NSAlert()
        a.alertStyle = danger.isEmpty ? .warning : .critical
        a.messageText = "Eliminare \(sel.count) elementi?"
        var info = sel.prefix(8).map { "• \($0.engine) · \($0.title) — \($0.size.map(formatBytes) ?? "?")" }.joined(separator: "\n")
        if sel.count > 8 { info += "\n… e altri \(sel.count - 8)" }
        info += "\n\nNon recuperabile dal Cestino (tranne la cache minikube)."
        if danger.contains(where: { $0.section == .volume }) { info += "\n⛔️ I volumi contengono dati persistenti (database, registry…): se li elimini i dati sono persi." }
        if danger.contains(where: { $0.section == .container && $0.inUse }) { info += "\n⚠️ Alcuni container sono in esecuzione e verranno fermati." }
        if danger.contains(where: { $0.section == .minikube }) { info += "\n⚠️ Eliminare un profilo minikube distrugge il cluster." }
        a.informativeText = info
        a.addButton(withTitle: "Elimina"); a.addButton(withTitle: "Annulla")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        run(sel.map { it in { () -> String? in
            if let t = it.trashPath { var l: [TrashEntry] = []; do { try trashLogged(t, &l) } catch { return "\(it.title): \(error.localizedDescription)" }
                DispatchQueue.main.async { TrashLog.shared.record("Container", l) }; return nil }
            guard let c = it.command else { return nil }
            let r = shell(c[0], Array(c.dropFirst()), timeout: 180)
            return r.status == 0 ? nil : "\(it.title): \(r.out.split(separator: "\n").first.map { String($0.prefix(100)) } ?? "errore")"
        } }, label: "Eliminazione")
    }

    enum Prune { case containers, images, volumes, build, all
        var title: String {
            switch self {
            case .containers: return "container fermati"
            case .images: return "immagini non usate"
            case .volumes: return "volumi non usati"
            case .build: return "cache di build"
            case .all: return "tutto ciò che non è in uso (container fermati, immagini, reti)"
            }
        }
        var args: [String] {
            switch self {
            case .containers: return ["container", "prune", "-f"]
            case .images: return ["image", "prune", "-a", "-f"]
            case .volumes: return ["volume", "prune", "-f"]
            case .build: return ["builder", "prune", "-a", "-f"]
            case .all: return ["system", "prune", "-a", "-f"]
            }
        }
    }

    func prune(_ engine: EngineInfo, _ kind: Prune) {
        guard !busy else { return }
        let label: String
        switch kind {
        case .images, .all: label = "Images"
        case .volumes: label = "Local Volumes"
        case .containers: label = "Containers"
        case .build: label = "Build Cache"
        }
        let est = reclaim(engine, label)
        if dryRunReport(count: 0, bytes: 0, detail: "\(engine.name) \(kind.args.joined(separator: " ")) — \(est)") { return }
        let a = NSAlert()
        a.alertStyle = kind == .volumes ? .critical : .warning
        a.messageText = "\(engine.name.capitalized): rimuovere \(kind.title)?"
        a.informativeText = "Esegue `\(engine.name) \(kind.args.joined(separator: " "))`. \(est)\nNon è recuperabile." +
            (kind == .volumes ? "\n⛔️ I volumi non collegati a un container possono contenere dati che ti servono ancora." : "")
        a.addButton(withTitle: "Esegui"); a.addButton(withTitle: "Annulla")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let bin = engine.bin
        run([{ () -> String? in
            let r = shell(bin, kind.args, timeout: 600)
            return r.status == 0 ? nil : "\(engine.name): \(r.out.split(separator: "\n").last.map { String($0.prefix(120)) } ?? "errore")"
        }], label: "Pulizia")
    }

    func compactVM() {
        guard let p = findBinary("podman"), !busy else { return }
        let before = vmDisk?.allocated ?? 0
        let a = NSAlert()
        a.messageText = "Compattare il disco della VM Podman?"
        a.informativeText = "Esegue `fstrim` dentro la macchina virtuale per restituire a macOS i blocchi liberi. Operazione sicura, può richiedere qualche minuto. Prima elimina immagini e volumi che non servono."
        a.addButton(withTitle: "Compatta"); a.addButton(withTitle: "Annulla")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if dryRunReport(count: 0, bytes: 0, detail: "podman machine ssh sudo fstrim -av") { return }
        run([{ () -> String? in
            let r = shell(p, ["machine", "ssh", "sudo fstrim -av"], timeout: 900)
            return r.status == 0 ? nil : "fstrim: \(r.out.split(separator: "\n").last.map { String($0.prefix(120)) } ?? "errore")"
        }], label: "Compattazione") { [weak self] in
            let after = podmanVMDisk()?.allocated ?? before
            self?.status = "Disco VM: \(formatBytes(before)) → \(formatBytes(after))" + (after < before ? " (recuperati \(formatBytes(before - after)))" : " (nessuna riduzione)")
        }
    }

    private func run(_ jobs: [() -> String?], label: String, done: (@MainActor () -> Void)? = nil) {
        busy = true; status = "\(label) in corso…"
        DispatchQueue.global(qos: .userInitiated).async {
            let errs = jobs.compactMap { $0() }
            DispatchQueue.main.async { [self] in
                busy = false
                load()
                done?()
                if status.hasSuffix("in corso…") { status = "\(label) completata" + (errs.isEmpty ? "" : " · \(errs.count) errori") }
                if !errs.isEmpty {
                    let e = NSAlert(); e.messageText = "Alcune operazioni non sono riuscite"
                    e.informativeText = errs.prefix(6).joined(separator: "\n"); e.runModal()
                }
            }
        }
    }
}

// MARK: - Vista

struct ContainerView: View {
    @ObservedObject var cont: ContainersModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(cont.engines) { e in engineBanner(e) }
            if !cont.engines.isEmpty { Divider() }
            List {
                ForEach(CSection.allCases, id: \.self) { sec in
                    let rows = cont.items.filter { $0.section == sec }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { row($0) }
                        } header: {
                            HStack {
                                Text(sec.rawValue).fontWeight(.semibold)
                                Text("\(rows.count)").foregroundStyle(.secondary)
                                Spacer()
                                let t = rows.reduce(0) { $0 + ($1.size ?? 0) }
                                if t > 0 { Text(formatBytes(t)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if cont.loading { ProgressView("Lettura…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                else if cont.items.isEmpty { Text("Nessun motore di container raggiungibile (Docker, Podman o minikube).").foregroundStyle(.secondary) }
            }
            Divider()
            HStack(spacing: 14) {
                if cont.selection.isEmpty { Text(cont.status) } else {
                    let t = cont.items.filter { cont.selection.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) }
                    Text("\(cont.selection.count) selezionati · \(formatBytes(t))").fontWeight(.medium)
                }
                Spacer()
                Text("Le dimensioni delle immagini condividono layer: il totale può superare lo spazio reale.")
            }
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear { cont.loadIfNeeded() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { cont.load() } label: { Label("Rianalizza", systemImage: "arrow.clockwise") }
                Menu {
                    ForEach(cont.engines.filter { $0.error == nil && $0.note == nil }) { e in
                        Section(e.name.capitalized) {
                            Button("Container fermati") { cont.prune(e, .containers) }
                            Button("Immagini non usate  \(e.summary.first { $0.label == "Images" }.map { "(recuperabili \($0.reclaim))" } ?? "")") { cont.prune(e, .images) }
                            Button("Volumi non usati  \(e.summary.first { $0.label == "Local Volumes" }.map { "(recuperabili \($0.reclaim))" } ?? "")") { cont.prune(e, .volumes) }
                            if e.name == "docker" { Button("Cache di build") { cont.prune(e, .build) } }
                            Button("Tutto ciò che non è in uso") { cont.prune(e, .all) }
                        }
                    }
                    if cont.vmDisk != nil { Divider(); Button("Compatta disco VM Podman (fstrim)") { cont.compactVM() } }
                } label: { Label("Pulizia", systemImage: "sparkles") }
                    .help("Pulizia guidata: prune, compattazione della VM")
                Button(role: .destructive) { cont.deleteSelected() } label: { Label("Elimina selezionati", systemImage: "trash") }
                    .disabled(cont.selection.isEmpty || cont.busy)
                GlobalToolbarButtons()
            }
        }
    }

    private func engineBanner(_ e: EngineInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: e.error == nil ? "shippingbox.fill" : "exclamationmark.triangle.fill").foregroundStyle(e.error == nil ? Color.blue : Color.orange)
                Text(e.name.capitalized).fontWeight(.semibold)
                Text(e.version).foregroundStyle(.secondary)
                Spacer()
                if let vm = cont.vmDisk, e.name == "podman" { Text("VM su disco: \(formatBytes(vm.allocated))").foregroundStyle(.orange).fontWeight(.medium) }
            }
            if let err = e.error { Text(err).font(.caption).foregroundStyle(.orange) }
            else if let n = e.note { Text(n).font(.caption).foregroundStyle(.secondary) }
            else if !e.summary.isEmpty {
                HStack(spacing: 16) {
                    ForEach(e.summary, id: \.label) { s in
                        Text("\(s.label): \(s.total) · \(s.size) · recuperabili \(s.reclaim)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder private func row(_ it: CItem) -> some View {
        HStack(spacing: 10) {
            if it.removable {
                Toggle("", isOn: Binding(get: { cont.selection.contains(it.id) },
                                         set: { if $0 { cont.selection.insert(it.id) } else { cont.selection.remove(it.id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            } else { Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 18) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(it.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    badge(it.engine, .blue)
                    if it.minikube { badge("minikube", .purple) }
                    if it.inUse && it.section != .vm { badge(it.section == .container ? "in esecuzione" : "in uso", .green) }
                    if it.section == .volume { badge("dati", .orange) }
                }
                Text(it.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let s = it.size { Text(formatBytes(s)).font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(s > 5_000_000_000 ? Color.red : s > 1_000_000_000 ? Color.orange : Color.primary) }
            else if it.trashPath != nil { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.18), in: Capsule()).foregroundStyle(c)
    }
}
