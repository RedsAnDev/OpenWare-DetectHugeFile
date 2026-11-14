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

struct TCell {
    let rect: CGRect
    let node: Node?          // nil = "file piccoli" aggregati
    let label: String
    let size: UInt64
    let depth: Int
}

/// Squarified treemap (Bruls et al.): `values` ordinati in modo decrescente → rettangoli con aspect ratio vicino a 1.
func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
    guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
    let total = values.reduce(0, +)
    guard total > 0 else { return values.map { _ in .zero } }
    let scale = Double(rect.width * rect.height) / total
    let areas = values.map { $0 * scale }
    var out = [CGRect](repeating: .zero, count: values.count)
    var r = rect
    var i = 0

    func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
        let s = row.reduce(0, +)
        guard s > 0, let mx = row.max(), let mn = row.min(), mn > 0 else { return .infinity }
        return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
    }

    while i < areas.count {
        let side = Double(min(r.width, r.height))
        var j = i + 1
        while j < areas.count, worst(areas[i...j], side) <= worst(areas[i..<j], side) { j += 1 }
        let row = areas[i..<j]
        let s = row.reduce(0, +)
        if r.width >= r.height {
            let w = CGFloat(s / Double(r.height))
            var y = r.minY
            for k in i..<j { let h = CGFloat(areas[k] / Double(w)); out[k] = CGRect(x: r.minX, y: y, width: w, height: h); y += h }
            r = CGRect(x: r.minX + w, y: r.minY, width: max(0, r.width - w), height: r.height)
        } else {
            let h = CGFloat(s / Double(r.width))
            var x = r.minX
            for k in i..<j { let w = CGFloat(areas[k] / Double(h)); out[k] = CGRect(x: x, y: r.minY, width: w, height: h); x += w }
            r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: max(0, r.height - h))
        }
        i = j
    }
    return out
}

private func items(of n: Node) -> [(Node?, String, UInt64)] {
    var arr: [(Node?, String, UInt64)] = n.children.filter { $0.size > 0 }.sorted { $0.size > $1.size }.map { ($0, $0.name, $0.size) }
    if n.ownSize > 0 { arr.append((nil, "file piccoli", n.ownSize)); arr.sort { $0.2 > $1.2 } }
    return arr
}

func layoutTreemap(_ focus: Node, size: CGSize) -> [TCell] {
    var cells: [TCell] = []
    let top = items(of: focus)
    let rects = squarify(top.map { Double($0.2) }, in: CGRect(origin: .zero, size: size))
    for (k, it) in top.enumerated() {
        let r = rects[k]
        guard r.width >= 2, r.height >= 2 else { continue }
        cells.append(TCell(rect: r, node: it.0, label: it.1, size: it.2, depth: 0))
        // secondo livello dentro le cartelle abbastanza grandi
        if let n = it.0, n.isDir, r.width > 90, r.height > 56 {
            let inner = CGRect(x: r.minX + 3, y: r.minY + 18, width: r.width - 6, height: r.height - 21)
            let kids = items(of: n)
            let kr = squarify(kids.map { Double($0.2) }, in: inner)
            for (j, kid) in kids.enumerated() where kr[j].width >= 3 && kr[j].height >= 3 {
                cells.append(TCell(rect: kr[j], node: kid.0, label: kid.1, size: kid.2, depth: 1))
            }
        }
    }
    return cells
}

private func color(for c: TCell) -> Color {
    guard let n = c.node else { return Color.gray.opacity(0.45) }
    var h: UInt64 = 1469598103934665603
    for b in n.name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    let hue = Double(h % 360) / 360
    if !n.isDir { return Color(hue: hue, saturation: 0.25, brightness: 0.78) }
    return c.depth == 0 ? Color(hue: hue, saturation: 0.55, brightness: 0.62) : Color(hue: hue, saturation: 0.6, brightness: 0.82)
}

struct MappaView: View {
    @ObservedObject var model: AppModel
    @State private var focus: Node?
    @State private var hover: TCell?

    private var current: Node? {
        guard let root = model.root else { return nil }
        if let f = focus {
            var n: Node? = f
            while let x = n { if x === root { return f }; n = x.parent }
        }
        return root
    }

    var body: some View {
        VStack(spacing: 0) {
            if let cur = current {
                breadcrumb(cur)
                Divider()
                GeometryReader { geo in
                    let cells = layoutTreemap(cur, size: geo.size)
                    Canvas { ctx, size in
                        for c in cells {
                            let r = c.rect.insetBy(dx: 0.5, dy: 0.5)
                            ctx.fill(Path(r), with: .color(color(for: c)))
                            ctx.stroke(Path(r), with: .color(.black.opacity(c.depth == 0 ? 0.55 : 0.25)), lineWidth: c.depth == 0 ? 1.2 : 0.5)
                            if c.node === hover?.node && c.label == hover?.label && c.depth == hover?.depth {
                                ctx.stroke(Path(r), with: .color(.white), lineWidth: 2)
                            }
                            if r.width > 60 && r.height > 15 {
                                ctx.drawLayer { l in
                                    l.clip(to: Path(r))
                                    let t = Text("\(c.label)  \(formatBytes(c.size))").font(.system(size: 11, weight: c.depth == 0 ? .semibold : .regular)).foregroundColor(.white)
                                    l.draw(t, at: CGPoint(x: r.minX + 4, y: r.minY + 2), anchor: .topLeading)
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hover = hit(cells, p) } else { hover = nil }
                    }
                    .gesture(SpatialTapGesture(count: 2).onEnded { v in
                        if let n = hit(cells, v.location)?.node, n.isDir, !n.children.isEmpty { focus = n }
                    })
                    .simultaneousGesture(SpatialTapGesture().onEnded { v in
                        if let n = hit(cells, v.location)?.node { model.selection = [n] } else { model.selection = [] }
                    })
                    .contextMenu {
                        if let n = hover?.node {
                            Button("Mostra nel Finder") { model.reveal([n]) }
                            if n.isDir { Button("Entra nella cartella") { focus = n } }
                            Divider()
                            Button("Sposta nel Cestino…") { model.selection = [n]; model.trashSelection() }
                        }
                    }
                }
                Divider()
                HStack {
                    if let h = hover {
                        Text(h.label).fontWeight(.semibold)
                        Text(formatBytes(h.size))
                        Text(String(format: "%.1f%% di %@", Double(h.size) / Double(max(1, cur.size)) * 100, cur.name))
                        if let n = h.node { Text(abbreviate(n.path)).lineLimit(1).truncationMode(.middle) }
                    } else {
                        Text("Passa sopra un blocco per i dettagli · doppio clic per entrare · clic destro per le azioni")
                    }
                    Spacer()
                }
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                Text(model.scanning ? "Scansione in corso…" : "Nessuna scansione: usa la tab Lista per scansionare una cartella.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: model.root?.name) { _ in focus = nil }
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { GlobalToolbarButtons() } }
    }

    private func hit(_ cells: [TCell], _ p: CGPoint) -> TCell? {
        cells.last { $0.rect.contains(p) }
    }

    private func breadcrumb(_ cur: Node) -> some View {
        var chain: [Node] = []
        var n: Node? = cur
        while let x = n { chain.insert(x, at: 0); n = x.parent }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(chain.enumerated()), id: \.offset) { i, node in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button { focus = node } label: {
                        Text(i == 0 ? abbreviate(node.name) : node.name).fontWeight(node === cur ? .semibold : .regular)
                    }.buttonStyle(.plain).foregroundStyle(node === cur ? Color.primary : Color.accentColor)
                }
                Text("· " + formatBytes(cur.size)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}
