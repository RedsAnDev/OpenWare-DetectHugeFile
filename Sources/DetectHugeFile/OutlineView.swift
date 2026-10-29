import AppKit
import SwiftUI

final class SizeCellView: NSTableCellView {
    var fraction: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        let w = (bounds.width - 4) * min(1, max(0, fraction))
        if w > 0.5 {
            let c: NSColor = fraction > 0.5 ? .systemRed : fraction > 0.2 ? .systemOrange : .systemBlue
            c.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: w, height: bounds.height - 4), xRadius: 3, yRadius: 3).fill()
        }
        super.draw(dirtyRect)
    }
}

final class FolderOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return row >= 0 ? menuProvider?() : nil
    }
}

struct FolderOutline: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let ov = FolderOutlineView()
        ov.rowHeight = 22
        ov.style = .inset
        ov.usesAlternatingRowBackgroundColors = true
        ov.allowsMultipleSelection = true
        ov.autosaveTableColumns = false
        ov.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        func col(_ id: String, _ title: String, _ w: CGFloat, key: SortKey?, min: CGFloat = 60) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = w; c.minWidth = min
            if let key { c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: key == .name) }
            return c
        }
        let name = col("name", "Nome", 380, key: .name, min: 160)
        let size = col("size", "Dimensione", 150, key: .size, min: 110)
        let files = col("files", "File", 80, key: .files)
        let mod = col("mtime", "Modificata", 120, key: .mtime, min: 100)
        let cre = col("btime", "Creata", 120, key: .btime, min: 100)
        let path = col("path", "Percorso", 300, key: .path, min: 100)
        [name, size, files, mod, cre, path].forEach { ov.addTableColumn($0) }
        ov.outlineTableColumn = name
        path.isHidden = true
        size.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.size.rawValue, ascending: false)
        ov.sortDescriptors = [NSSortDescriptor(key: SortKey.size.rawValue, ascending: false)]

        ov.dataSource = c
        ov.delegate = c
        ov.target = c
        ov.doubleAction = #selector(Coordinator.doubleClicked)
        ov.onDelete = { [weak model] in model?.trashSelection() }
        ov.menuProvider = { [weak c] in c?.makeMenu() ?? NSMenu() }
        c.outline = ov

        let sv = NSScrollView()
        sv.documentView = ov
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        guard c.lastToken != model.reloadToken, let ov = c.outline else { return }
        c.lastToken = model.reloadToken
        ov.tableColumns.first { $0.identifier.rawValue == "path" }?.isHidden = !model.isFlat
        ov.outlineTableColumn = ov.tableColumns.first
        ov.reloadData()
        if !model.isFlat, let r = model.root, ov.numberOfRows > 0, c.expandedRoot !== r {
            c.expandedRoot = r
            ov.expandItem(r)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let model: AppModel
        weak var outline: FolderOutlineView?
        var lastToken = -1
        var expandedRoot: Node?
        private let dateFmt: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "dd/MM/yy HH:mm"; return f
        }()
        private let folderIcon: NSImage = {
            let i = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage()
            return i.withSymbolConfiguration(.init(paletteColors: [.systemBlue])) ?? i
        }()
        private let fileIcon = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)

        init(_ m: AppModel) { model = m }

        // MARK: data source
        private func roots() -> [Node] {
            if model.isFlat { return model.flatItems }
            return model.root.map { [$0] } ?? []
        }

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let n = item as? Node else { return roots().count }
            return model.isFlat ? 0 : n.visibleChildren(model.config).count
        }

        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let n = item as? Node else { return roots()[index] }
            return n.visibleChildren(model.config)[index]
        }

        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let n = item as? Node, n.isDir, !model.isFlat else { return false }
            return !n.visibleChildren(model.config).isEmpty
        }

        func outlineView(_ ov: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let d = ov.sortDescriptors.first, let k = d.key, let key = SortKey(rawValue: k) else { return }
            model.setSort(key, ascending: d.ascending)
        }

        // MARK: celle
        private func label(_ id: String, _ ov: NSOutlineView, imageView: Bool = false, size: Bool = false) -> NSTableCellView {
            let ident = NSUserInterfaceItemIdentifier(id)
            if let v = ov.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView { return v }
            let v: NSTableCellView = size ? SizeCellView() : NSTableCellView()
            v.identifier = ident
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(tf); v.textField = tf
            var cs = [tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
                      tf.centerYAnchor.constraint(equalTo: v.centerYAnchor)]
            if imageView {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(iv); v.imageView = iv
                cs += [iv.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
                       iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                       iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                       tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6)]
            } else {
                cs.append(tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6))
            }
            NSLayoutConstraint.activate(cs)
            return v
        }

        private func date(_ t: Int64) -> String { t == 0 ? "—" : dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }

        func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? Node, let id = col?.identifier.rawValue else { return nil }
            switch id {
            case "name":
                let v = label("name", ov, imageView: true)
                v.imageView?.image = n.isDir ? folderIcon : fileIcon
                v.imageView?.contentTintColor = n.isDir ? nil : .secondaryLabelColor
                let s = NSMutableAttributedString(string: n.name)
                if n.denied { s.append(NSAttributedString(string: "  accesso negato", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 10)])) }
                else if let h = regenerableHints[n.name], n.isDir { s.append(NSAttributedString(string: "  \(h)", attributes: [.foregroundColor: NSColor.systemGreen, .font: NSFont.systemFont(ofSize: 10, weight: .medium)])) }
                v.textField?.attributedStringValue = s
                v.toolTip = n.path
                return v
            case "size":
                let v = label("size", ov, size: true) as! SizeCellView
                v.textField?.stringValue = formatBytes(n.size)
                v.textField?.alignment = .right
                v.textField?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                let ref: UInt64 = model.isFlat ? (model.flatItems.first?.size ?? 1) : (n.parent?.size ?? n.size)
                v.fraction = ref == 0 ? 0 : CGFloat(n.size) / CGFloat(ref)
                v.needsDisplay = true
                return v
            case "files":
                let v = label("files", ov); v.textField?.stringValue = n.isDir ? n.files.formatted() : "—"
                v.textField?.alignment = .right; v.textField?.textColor = .secondaryLabelColor
                return v
            case "mtime":
                let v = label("mtime", ov); v.textField?.stringValue = date(n.mtime); v.textField?.textColor = .secondaryLabelColor
                return v
            case "btime":
                let v = label("btime", ov); v.textField?.stringValue = date(n.btime); v.textField?.textColor = .secondaryLabelColor
                return v
            case "path":
                let v = label("path", ov); v.textField?.stringValue = n.path; v.textField?.textColor = .secondaryLabelColor
                v.textField?.lineBreakMode = .byTruncatingHead
                return v
            default: return nil
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let ov = outline else { return }
            model.selection = ov.selectedRowIndexes.compactMap { ov.item(atRow: $0) as? Node }
        }

        // MARK: interazione
        @objc func doubleClicked() {
            guard let ov = outline, ov.clickedRow >= 0, let n = ov.item(atRow: ov.clickedRow) as? Node else { return }
            if model.isFlat { model.reveal([n]); return }
            if ov.isItemExpanded(n) { ov.collapseItem(n) } else { ov.expandItem(n) }
        }

        func makeMenu() -> NSMenu {
            let m = NSMenu()
            func add(_ t: String, _ s: Selector) { let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; m.addItem(i) }
            add("Mostra nel Finder", #selector(reveal))
            add("Copia percorso", #selector(copyPath))
            if model.selection.count == 1, model.selection[0].isDir { add("Scansiona solo questa cartella", #selector(scanHere)) }
            m.addItem(.separator())
            add("Sposta nel Cestino…", #selector(trash))
            return m
        }
        @objc func reveal() { model.reveal(model.selection) }
        @objc func copyPath() { model.copyPath(model.selection) }
        @objc func scanHere() { if let n = model.selection.first { model.scan(path: n.path) } }
        @objc func trash() { model.trashSelection() }
    }
}
