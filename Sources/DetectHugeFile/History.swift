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

struct Snapshot: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let root: String
    let total: UInt64
    let dirs: [String: UInt64]     // cartelle ≥ 20 MB
}

struct DeltaRow: Identifiable {
    let id: String
    let before: UInt64
    let after: UInt64
    var delta: Int64 { Int64(after) - Int64(before) }
    var path: String { id }
}

enum SnapshotStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DetectHugeFile/snapshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func loadAll() -> [Snapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        return files.compactMap { try? dec.decode(Snapshot.self, from: Data(contentsOf: $0)) }.sorted { $0.date < $1.date }
    }

    static func write(_ s: Snapshot) {
        let url = dir.appendingPathComponent("\(Int(s.date.timeIntervalSince1970))-\(s.id.uuidString).json")
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    /// Tiene le ultime 15 istantanee per radice.
    static func prune(root: String) {
        let same = loadAll().filter { $0.root == root }
        guard same.count > 15 else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for old in same.prefix(same.count - 15) {
            for f in files where f.lastPathComponent.contains(old.id.uuidString) { try? FileManager.default.removeItem(at: f) }
        }
    }

    static func deleteAll() {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

extension Snapshot {
    /// Istantanea delle cartelle ≥ 20 MB di una scansione.
    static func make(root: Node) -> Snapshot {
        var dirs: [String: UInt64] = [:]
        var stack = [root]
        while let n = stack.popLast() {
            for c in n.children where c.isDir && c.size >= 20 << 20 { dirs[c.path] = c.size; stack.append(c) }
        }
        return Snapshot(id: UUID(), date: Date(), root: root.path, total: root.size, dirs: dirs)
    }
}

func computeDeltas(_ a: Snapshot, _ b: Snapshot, minMB: Int, onlyGrown: Bool) -> [DeltaRow] {
    let minB = Int64(minMB) << 20
    var out: [DeltaRow] = []
    for p in Set(a.dirs.keys).union(b.dirs.keys) {
        let r = DeltaRow(id: p, before: a.dirs[p] ?? 0, after: b.dirs[p] ?? 0)
        if abs(r.delta) >= minB, !onlyGrown || r.delta > 0 { out.append(r) }
    }
    return out
}

@MainActor
final class HistoryModel: ObservableObject {
    static let shared = HistoryModel()
    @Published var snapshots: [Snapshot] = []
    @Published var fromID: UUID?
    @Published var toID: UUID?
    @Published var onlyGrown = false
    @Published var minMB = 20

    init() {
        load()
        // il server MCP può aver salvato nuove istantanee
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    private func load() {
        snapshots = SnapshotStore.loadAll()
        pickDefaults()
    }

    private func pickDefaults() {
        guard let last = snapshots.last else { fromID = nil; toID = nil; return }
        let same = snapshots.filter { $0.root == last.root }
        toID = last.id
        fromID = same.count > 1 ? same[same.count - 2].id : nil
    }

    func save(root: Node) {
        let snap = Snapshot.make(root: root)
        SnapshotStore.write(snap)
        SnapshotStore.prune(root: snap.root)
        load()
    }

    var from: Snapshot? { snapshots.first { $0.id == fromID } }
    var to: Snapshot? { snapshots.first { $0.id == toID } }

    func rows() -> [DeltaRow] {
        guard let a = from, let b = to, a.id != b.id else { return [] }
        return computeDeltas(a, b, minMB: minMB, onlyGrown: onlyGrown)
    }

    func exportTable() -> ExportTable {
        ExportTable(headers: ["Percorso", "Prima (byte)", "Dopo (byte)", "Variazione (byte)"],
                    rows: rows().sorted { $0.delta > $1.delta }.map { [$0.path, String($0.before), String($0.after), String($0.delta)] })
    }

    func deleteAll() { SnapshotStore.deleteAll(); load() }
}

private let histFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM/yy HH:mm"; return f }()
private func signed(_ d: Int64) -> String { (d >= 0 ? "+" : "−") + formatBytes(UInt64(abs(d))) }

struct StoricoView: View {
    @ObservedObject var hist: HistoryModel
    @State private var order = [KeyPathComparator(\DeltaRow.delta, order: .reverse)]

    private func label(_ s: Snapshot) -> String { "\(histFmt.string(from: s.date)) · \(abbreviate(s.root)) · \(formatBytes(s.total))" }

    var body: some View {
        let rows = hist.rows().sorted(using: order)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Da", selection: $hist.fromID) {
                    Text("—").tag(UUID?.none)
                    ForEach(hist.snapshots) { Text(label($0)).tag(UUID?.some($0.id)) }
                }
                Picker("A", selection: $hist.toID) {
                    Text("—").tag(UUID?.none)
                    ForEach(hist.snapshots) { Text(label($0)).tag(UUID?.some($0.id)) }
                }
                Picker("Soglia", selection: $hist.minMB) {
                    Text("≥ 20 MB").tag(20); Text("≥ 100 MB").tag(100); Text("≥ 500 MB").tag(500); Text("≥ 1 GB").tag(1024)
                }.frame(width: 140)
                Toggle("Solo crescite", isOn: $hist.onlyGrown)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ZStack {
                Table(rows, sortOrder: $order) {
                    TableColumn("Cartella", value: \.path) { r in
                        Text(abbreviate(r.path)).lineLimit(1).truncationMode(.middle).help(r.path)
                    }
                    TableColumn("Prima", value: \.before) { r in Text(r.before == 0 ? "nuova" : formatBytes(r.before)).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                    TableColumn("Dopo", value: \.after) { r in Text(r.after == 0 ? "rimossa" : formatBytes(r.after)).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                    TableColumn("Variazione", value: \.delta) { r in
                        Text(signed(r.delta)).font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(r.delta > 0 ? Color.red : Color.green)
                    }.width(min: 110, ideal: 120)
                }
                if hist.snapshots.count < 2 {
                    Text("Servono almeno due scansioni della stessa cartella.\nOgni scansione dalla tab Lista salva un'istantanea: riscansiona più tardi per confrontare.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                } else if rows.isEmpty {
                    Text("Nessuna variazione sopra la soglia").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                if let a = hist.from, let b = hist.to, a.id != b.id {
                    let d = Int64(b.total) - Int64(a.total)
                    Text("Totale: \(formatBytes(a.total)) → \(formatBytes(b.total)) (\(signed(d)))").fontWeight(.medium)
                } else { Text("\(hist.snapshots.count) istantanee salvate") }
                Spacer()
                Button("Elimina storico") { hist.deleteAll() }.buttonStyle(.link)
            }
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { GlobalToolbarButtons() } }
    }
}
