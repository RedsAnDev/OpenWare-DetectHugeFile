import Foundation
import AppKit
import SwiftUI

enum SysKind: String, CaseIterable {
    case simulator = "Simulatori Xcode", backup = "Backup iPhone/iPad", snapshot = "Snapshot locali Time Machine"
    var undoable: Bool { self == .backup }
}

struct SysItem: Identifiable {
    let id: String
    let kind: SysKind
    let title: String
    let subtitle: String
    let path: String?
    var size: UInt64?
    var denied = false
    var blocked = false      // non selezionabile (es. simulatore acceso)
}

@MainActor
final class SystemModel: ObservableObject {
    @Published var items: [SysItem] = []
    @Published var selection: Set<String> = []
    @Published var loading = false
    @Published var busy = false
    @Published var status = ""
    @Published var backupDenied = false
    private let measurer = SizeMeasurer()
    private var started = false

    func loadIfNeeded() { if !started { load() } }

    func load() {
        started = true
        loading = true; selection = []; items = []; backupDenied = false
        measurer.cancel()
        DispatchQueue.global(qos: .userInitiated).async {
            let sims = Self.listSimulators()
            let snaps = Self.listSnapshots()
            let (backups, denied) = Self.listBackups()
            DispatchQueue.main.async { [self] in
                items = sims + backups + snaps
                backupDenied = denied
                loading = false
                measurer.onIdle = { [weak self] in self?.status = "Misura completata" }
                status = "Misura delle dimensioni…"
                for it in items {
                    guard let p = it.path else { continue }
                    measurer.add(p) { [weak self] size, denied in
                        guard let self, let i = self.items.firstIndex(where: { $0.id == it.id }) else { return }
                        self.items[i].size = size; self.items[i].denied = denied
                    }
                }
                if measurer.isIdle { status = "" }
            }
        }
    }

    // MARK: sorgenti dati

    nonisolated static func listSimulators() -> [SysItem] {
        let r = shell("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 20)
        guard r.status == 0, let d = r.out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let devs = j["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [SysItem] = []
        for (rt, list) in devs {
            let runtime = rt.components(separatedBy: "SimRuntime.").last?.replacingOccurrences(of: "-", with: " ") ?? rt
            for x in list {
                guard let udid = x["udid"] as? String, let name = x["name"] as? String else { continue }
                let state = x["state"] as? String ?? ""
                let avail = (x["isAvailable"] as? Bool) ?? true
                let booted = x["lastBootedAt"] as? String
                let dev = ((x["dataPath"] as? String).map { ($0 as NSString).deletingLastPathComponent }) ?? NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices/" + udid
                var sub = runtime.replacingOccurrences(of: ".", with: ".")
                sub += avail ? "" : " · non disponibile"
                if state == "Booted" { sub += " · ACCESO" }
                if let b = booted { sub += " · ultimo avvio " + String(b.prefix(10)) } else { sub += " · mai avviato" }
                out.append(SysItem(id: "sim:" + udid, kind: .simulator, title: name, subtitle: sub, path: dev, blocked: state == "Booted"))
            }
        }
        return out.sorted { $0.subtitle < $1.subtitle }
    }

    nonisolated static func listSnapshots() -> [SysItem] {
        let r = shell("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15)
        return r.out.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard s.hasPrefix("com.apple.TimeMachine.") else { return nil }
            let date = s.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: "")
            return SysItem(id: "snap:" + date, kind: .snapshot, title: date, subtitle: "Snapshot APFS locale (dimensione non misurabile)", path: nil)
        }
    }

    nonisolated static func listBackups() -> ([SysItem], Bool) {
        let base = NSHomeDirectory() + "/Library/Application Support/MobileSync/Backup"
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(atPath: base) else {
            return ([], fm.fileExists(atPath: base))
        }
        var out: [SysItem] = []
        for d in list where !d.hasPrefix(".") {
            let dir = base + "/" + d
            let info = NSDictionary(contentsOfFile: dir + "/Info.plist")
            let name = (info?["Device Name"] as? String) ?? d
            var sub = (info?["Product Name"] as? String).map { $0 + " " } ?? ""
            sub += (info?["Product Version"] as? String) ?? ""
            if let date = info?["Last Backup Date"] as? Date {
                let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"
                sub += " · ultimo backup " + f.string(from: date)
            }
            out.append(SysItem(id: "bak:" + dir, kind: .backup, title: name, subtitle: sub, path: dir))
        }
        return (out, false)
    }

    // MARK: azioni

    func exportTable() -> ExportTable {
        ExportTable(headers: ["Tipo", "Nome", "Dettagli", "Percorso", "Byte", "Dimensione"],
                    rows: items.map { [$0.kind.rawValue, $0.title, $0.subtitle, $0.path ?? "", String($0.size ?? 0), $0.size.map(formatBytes) ?? ""] })
    }

    func deleteUnavailableSimulators() {
        let a = NSAlert()
        a.messageText = "Eliminare i simulatori non disponibili?"
        a.informativeText = "Esegue `xcrun simctl delete unavailable`. Non è recuperabile dal Cestino."
        a.addButton(withTitle: "Elimina"); a.addButton(withTitle: "Annulla")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if dryRunReport(count: items.filter { $0.subtitle.contains("non disponibile") }.count, bytes: 0, detail: "xcrun simctl delete unavailable") { return }
        busy = true
        DispatchQueue.global().async {
            let r = shell("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 120)
            DispatchQueue.main.async { [self] in busy = false; status = r.status == 0 ? "Simulatori non disponibili eliminati" : "Errore: \(r.out)"; load() }
        }
    }

    func deleteSelected() {
        let sel = items.filter { selection.contains($0.id) && !$0.blocked }
        guard !sel.isEmpty, !busy else { return }
        let total = sel.reduce(0) { $0 + ($1.size ?? 0) }
        if dryRunReport(count: sel.count, bytes: total, detail: sel.prefix(10).map { "• \($0.kind.rawValue): \($0.title)" }.joined(separator: "\n")) { return }
        let permanent = sel.contains { !$0.kind.undoable }
        let a = NSAlert()
        a.alertStyle = permanent ? .critical : .warning
        a.messageText = "Eliminare \(sel.count) elementi?"
        a.informativeText = sel.prefix(8).map { "• \($0.title) — \($0.size.map(formatBytes) ?? "?")" }.joined(separator: "\n") +
            "\n\nTotale: \(formatBytes(total))." +
            (permanent ? "\n⛔️ Simulatori e snapshot vengono eliminati definitivamente (non passano dal Cestino). I backup iOS vanno nel Cestino." : "")
        a.addButton(withTitle: "Elimina"); a.addButton(withTitle: "Annulla")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }

        busy = true; status = "Eliminazione in corso…"
        DispatchQueue.global(qos: .userInitiated).async {
            var fails: [String] = []
            var log: [TrashEntry] = []
            for it in sel {
                switch it.kind {
                case .simulator:
                    let udid = String(it.id.dropFirst(4))
                    _ = shell("/usr/bin/xcrun", ["simctl", "shutdown", udid], timeout: 20)
                    let r = shell("/usr/bin/xcrun", ["simctl", "delete", udid], timeout: 60)
                    if r.status != 0 { fails.append("\(it.title): \(r.out.prefix(80))") }
                case .backup:
                    do { try trashLogged(it.path!, &log) } catch { fails.append("\(it.title): \(error.localizedDescription)") }
                case .snapshot:
                    let script = "do shell script \"tmutil deletelocalsnapshots \(it.title)\" with administrator privileges"
                    var err: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&err)
                    if err != nil { fails.append("Snapshot \(it.title): operazione annullata o negata") }
                }
            }
            DispatchQueue.main.async { [self] in
                TrashLog.shared.record("Sistema", log)
                busy = false
                status = "Eliminati \(sel.count - fails.count) elementi" + (fails.isEmpty ? "" : " · \(fails.count) con problemi")
                if !fails.isEmpty {
                    let e = NSAlert(); e.messageText = "Alcune operazioni non sono riuscite"
                    e.informativeText = fails.prefix(6).joined(separator: "\n"); e.runModal()
                }
                load()
            }
        }
    }
}

struct SistemaView: View {
    @ObservedObject var sys: SystemModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(SysKind.allCases, id: \.self) { kind in
                    let rows = sys.items.filter { $0.kind == kind }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
                    Section {
                        if rows.isEmpty {
                            Text(emptyText(kind)).foregroundStyle(.secondary)
                        }
                        ForEach(rows) { row($0) }
                    } header: {
                        HStack {
                            Text(kind.rawValue).fontWeight(.semibold)
                            Spacer()
                            let t = rows.reduce(0) { $0 + ($1.size ?? 0) }
                            if t > 0 { Text(formatBytes(t)).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay { if sys.loading { ProgressView("Lettura…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
            Divider()
            HStack(spacing: 14) {
                if sys.selection.isEmpty { Text(sys.status) } else {
                    let t = sys.items.filter { sys.selection.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) }
                    Text("\(sys.selection.count) selezionati · \(formatBytes(t))").fontWeight(.medium)
                }
                Spacer()
            }
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear { sys.loadIfNeeded() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { sys.load() } label: { Label("Rianalizza", systemImage: "arrow.clockwise") }
                Button { sys.deleteUnavailableSimulators() } label: { Label("Simulatori non disponibili", systemImage: "iphone.slash") }
                    .help("Elimina i simulatori non più disponibili")
                Button(role: .destructive) { sys.deleteSelected() } label: { Label("Elimina selezionati", systemImage: "trash") }
                    .disabled(sys.selection.isEmpty || sys.busy)
                GlobalToolbarButtons()
            }
        }
    }

    private func emptyText(_ k: SysKind) -> String {
        switch k {
        case .simulator: return "Nessun simulatore (Xcode non installato?)"
        case .backup: return sys.backupDenied ? "Cartella protetta: concedi l'Accesso completo al disco all'app per vedere i backup." : "Nessun backup locale"
        case .snapshot: return "Nessuno snapshot locale"
        }
    }

    @ViewBuilder private func row(_ it: SysItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { sys.selection.contains(it.id) },
                                     set: { if $0 { sys.selection.insert(it.id) } else { sys.selection.remove(it.id) } }))
                .labelsHidden().toggleStyle(.checkbox).disabled(it.blocked)
            VStack(alignment: .leading, spacing: 2) {
                Text(it.title).fontWeight(.medium)
                Text(it.subtitle).font(.caption).foregroundStyle(it.blocked ? Color.orange : .secondary)
            }
            Spacer()
            if it.denied { Text("negato").foregroundStyle(.red).font(.caption) }
            else if let s = it.size { Text(formatBytes(s)).font(.system(.body, design: .monospaced).weight(.semibold)) }
            else if it.path != nil { ProgressView().controlSize(.small) }
            if let p = it.path {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Mostra nel Finder")
            }
        }
        .padding(.vertical, 2)
    }
}
