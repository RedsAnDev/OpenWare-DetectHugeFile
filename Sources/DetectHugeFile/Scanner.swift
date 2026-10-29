import Foundation
import Darwin

/// Scanner parallelo basato su getattrlistbulk(2): una sola syscall per molte voci di directory,
/// niente stat per file. Dimensioni = byte allocati su disco (come `du`), hard link contati una volta.
final class Scanner {
    let root: Node
    let rootPath: String
    var onFinish: (() -> Void)?

    let bigFileThreshold: UInt64

    private let queue = OperationQueue()
    private let lock = NSLock()
    private var pending = 0
    private var seenLinks = Set<UInt64>()
    private var _cancelled = false
    private var _bytes: UInt64 = 0, _files = 0, _dirs = 0
    private var _current = ""
    private let skipPaths: Set<String>
    static let skipNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems"]

    init(path: String, extraSkip: Set<String> = [], bigFileThreshold: UInt64 = 10 << 20) {
        self.bigFileThreshold = bigFileThreshold
        rootPath = path
        root = Node(name: path, isDir: true, parent: nil)
        let home = NSHomeDirectory()
        skipPaths = Set(["/Volumes", "/System/Volumes", "/dev", "/private/var/vm", "/.vol", "/Network",
                     "/.Spotlight-V100", "/.fseventsd", home + "/Library/CloudStorage"]).union(extraSkip)
        queue.maxConcurrentOperationCount = min(16, max(4, ProcessInfo.processInfo.activeProcessorCount * 2))
        queue.qualityOfService = .userInitiated
    }

    var stats: (bytes: UInt64, files: Int, dirs: Int, current: String) {
        lock.lock(); defer { lock.unlock() }
        return (_bytes, _files, _dirs, _current)
    }

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
        queue.cancelAllOperations()
    }

    func start() {
        var st = stat()
        if lstat(rootPath, &st) == 0 { root.btime = Int64(st.st_birthtimespec.tv_sec); root.mtime = Int64(st.st_mtimespec.tv_sec) }
        enqueue(root, rootPath)
    }

    private func enqueue(_ node: Node, _ path: String) {
        lock.lock(); pending += 1; lock.unlock()
        queue.addOperation { [self] in
            if !cancelled { scan(node, path) }
            finishOne()
        }
    }

    private func finishOne() {
        lock.lock(); pending -= 1; let done = pending == 0; lock.unlock()
        guard done else { return }
        if !cancelled { aggregate(root) }
        DispatchQueue.main.async { [self] in onFinish?() }
    }

    private func aggregate(_ n: Node) {
        var size = n.ownSize, files = n.ownFiles, m = n.mtime
        for c in n.children {
            if c.isDir { aggregate(c) }
            size += c.size; files += c.files; m = max(m, c.mtime)
        }
        n.size = size; n.files = files; n.mtime = m
    }

    private func scan(_ node: Node, _ path: String) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { node.denied = true; return }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(bitPattern: Int32(bitPattern: UInt32(ATTR_CMN_RETURNED_ATTRS))) |
            attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)

        let bufSize = 1 << 18
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var bytes: UInt64 = 0, nfiles = 0, ndirs = 0
        var subdirs: [(Node, String)] = []

        loop: while true {
            let n = getattrlistbulk(fd, &al, buf, bufSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if n < 0 { node.denied = true; break }
            if n == 0 { break }
            var p = UnsafeRawPointer(buf)
            for _ in 0..<n {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                var q = p + 4
                let ret = q.loadUnaligned(as: attribute_set_t.self)
                q += MemoryLayout<attribute_set_t>.size
                defer { p += length }

                var name = ""
                if ret.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = q.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (q + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    q += MemoryLayout<attrreference_t>.size
                }
                var objtype: UInt32 = 0
                if ret.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { objtype = q.loadUnaligned(as: UInt32.self); q += 4 }
                var btime: Int64 = 0, mtime: Int64 = 0
                if ret.commonattr & attrgroup_t(ATTR_CMN_CRTIME) != 0 { btime = Int64(q.loadUnaligned(as: timespec.self).tv_sec); q += MemoryLayout<timespec>.size }
                if ret.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 { mtime = Int64(q.loadUnaligned(as: timespec.self).tv_sec); q += MemoryLayout<timespec>.size }
                var fileID: UInt64 = 0
                if ret.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 { fileID = q.loadUnaligned(as: UInt64.self); q += 8 }
                var links: UInt32 = 1
                if ret.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { links = q.loadUnaligned(as: UInt32.self); q += 4 }
                var alloc: UInt64 = 0
                var hasAlloc = false
                if ret.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { alloc = UInt64(max(0, q.loadUnaligned(as: Int64.self))); q += 8; hasAlloc = true }
                // alcuni filesystem (exFAT, FAT, NTFS, SMB) non forniscono ALLOCSIZE: ripiega sulla dimensione logica
                if ret.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                    let dl = UInt64(max(0, q.loadUnaligned(as: Int64.self))); q += 8
                    if !hasAlloc { alloc = dl }
                }

                if name.isEmpty { continue }

                if objtype == UInt32(VDIR.rawValue) {
                    let full = path == "/" ? "/" + name : path + "/" + name
                    if skipPaths.contains(full) || Scanner.skipNames.contains(name) { continue }
                    let child = Node(name: name, isDir: true, parent: node)
                    child.btime = btime; child.mtime = mtime
                    node.children.append(child)
                    subdirs.append((child, full))
                    ndirs += 1
                } else {
                    if links > 1 {
                        lock.lock(); let fresh = seenLinks.insert(fileID).inserted; lock.unlock()
                        if !fresh { alloc = 0 }
                    }
                    nfiles += 1
                    bytes += alloc
                    if alloc >= bigFileThreshold {
                        let leaf = Node(name: name, isDir: false, parent: node)
                        leaf.size = alloc; leaf.files = 1; leaf.mtime = mtime; leaf.btime = btime
                        node.children.append(leaf)
                    } else {
                        node.ownSize += alloc; node.ownFiles += 1
                        if mtime > node.mtime { node.mtime = mtime }
                    }
                }
            }
        }

        lock.lock(); _bytes += bytes; _files += nfiles; _dirs += ndirs; _current = path; lock.unlock()
        for (c, p) in subdirs { enqueue(c, p) }
    }
}
