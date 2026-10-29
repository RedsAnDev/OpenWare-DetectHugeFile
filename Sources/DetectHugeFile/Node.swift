import Foundation

/// Nodo dell'albero: cartella oppure file "grosso" (i file piccoli sono solo aggregati nella cartella).
final class Node {
    let name: String
    let isDir: Bool
    unowned(unsafe) var parent: Node?

    var size: UInt64 = 0          // dimensione allocata aggregata (come `du`)
    var ownSize: UInt64 = 0       // file piccoli direttamente contenuti (non rappresentati come nodi)
    var files = 0                 // numero di file aggregato
    var ownFiles = 0
    var mtime: Int64 = 0          // ultima modifica di qualunque cosa contenuta (cartelle) / del file
    var btime: Int64 = 0          // data di creazione
    var children: [Node] = []
    var denied = false

    private var cacheGen = -1
    private var cache: [Node] = []
    lazy var lname: String = name.lowercased()

    init(name: String, isDir: Bool, parent: Node?) {
        self.name = name
        self.isDir = isDir
        self.parent = parent
    }

    var path: String {
        guard let p = parent else { return name }
        let pp = p.path
        return pp == "/" ? "/" + name : pp + "/" + name
    }

    var depth: Int { var d = 0; var n = parent; while let x = n { d += 1; n = x.parent }; return d }

    func visibleChildren(_ cfg: ViewConfig) -> [Node] {
        if cacheGen == cfg.generation { return cache }
        var arr = cfg.showFiles ? children : children.filter { $0.isDir }
        arr.sort(by: cfg.less)
        cache = arr
        cacheGen = cfg.generation
        return arr
    }

    /// Stacca il nodo dall'albero sottraendo le sue dimensioni agli antenati.
    func detach() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        var a: Node? = p
        while let n = a {
            n.size -= min(n.size, size)
            n.files -= min(n.files, files)
            a = n.parent
        }
        parent = nil
    }

    func isDescendant(of other: Node) -> Bool {
        var n = parent
        while let x = n { if x === other { return true }; n = x.parent }
        return false
    }
}

enum SortKey: String { case name, size, files, mtime, btime, path }

/// Configurazione di visualizzazione condivisa (ordinamento, filtro file). `generation` invalida le cache.
final class ViewConfig {
    var key: SortKey = .size
    var ascending = false
    var showFiles = true
    var generation = 0

    func less(_ a: Node, _ b: Node) -> Bool {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> Bool? {
            if x == y { return nil }
            return ascending ? x < y : x > y
        }
        switch key {
        case .name:  if let r = cmp(a.lname, b.lname) { return r }
        case .size:  if let r = cmp(a.size, b.size) { return r }
        case .files: if let r = cmp(a.files, b.files) { return r }
        case .mtime: if let r = cmp(a.mtime, b.mtime) { return r }
        case .btime: if let r = cmp(a.btime, b.btime) { return r }
        case .path:  if let r = cmp(a.path, b.path) { return r }
        }
        return a.lname < b.lname
    }
}

/// Nomi tipici di cartelle rigenerabili / sicure da cancellare.
let regenerableHints: [String: String] = [
    "node_modules": "rigenerabile · npm", ".venv": "rigenerabile · Python", "venv": "rigenerabile · Python",
    "__pycache__": "rigenerabile", ".tox": "rigenerabile", "Pods": "rigenerabile · CocoaPods",
    ".gradle": "cache Gradle", ".next": "rigenerabile", ".nuxt": "rigenerabile", ".terraform": "rigenerabile",
    "DerivedData": "rigenerabile · Xcode", "Caches": "cache", ".cache": "cache", ".npm": "cache npm",
    ".pnpm-store": "cache pnpm", ".Trash": "Cestino", "CoreSimulator": "simulatori iOS",
    "iOS DeviceSupport": "simboli debug iOS", "Archives": "archivi Xcode", ".parcel-cache": "cache",
    ".turbo": "cache", ".m2": "cache Maven", "Logs": "log",
]

func formatBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file)
}
