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

enum Risk { case safe, caution }

enum CleanMode {
    case contents                       // sposta il contenuto della cartella nel Cestino
    case emptyTrash                     // svuota il Cestino via Finder
    case command(String)                // comando di shell (es. brew cleanup)
    case manual(String)                 // niente pulizia automatica: serve valutazione (o privilegi)
}

struct KnownItem: Identifiable {
    let id: String
    let category: String
    let title: String
    let path: String
    let note: String
    let risk: Risk
    let mode: CleanMode

    var cleanable: Bool { if case .manual = mode { return false }; return true }
}

private let H = NSHomeDirectory()
private func k(_ cat: String, _ title: String, _ path: String, _ note: String, _ risk: Risk = .safe, _ mode: CleanMode = .contents) -> KnownItem {
    KnownItem(id: path + "|" + title, category: cat, title: title, path: path.hasPrefix("/") ? path : H + "/" + path, note: note, risk: risk, mode: mode)
}

let knownItems: [KnownItem] = [
    // Sistema e utente
    k("macOS", "Cestino", ".Trash", "Elementi già eliminati: svuotandolo si recupera subito lo spazio.", .safe, .emptyTrash),
    k("macOS", "Cache utente", "Library/Caches", "Cache delle app, rigenerate automaticamente.", .safe),
    k("macOS", "Log utente e crash report", "Library/Logs", "Log applicativi e report di crash.", .safe),
    k("macOS", "Allegati Mail scaricati", "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Copie degli allegati aperti da Mail.", .safe),
    k("macOS", "Backup iPhone/iPad", "Library/Application Support/MobileSync/Backup", "Backup locali dei dispositivi: cancellali solo se non ti servono.", .caution, .manual("Valuta da Finder → dispositivo → Gestisci backup")),
    k("macOS", "Cache di sistema", "/Library/Caches", "Richiede privilegi di amministratore.", .safe, .manual("Serve sudo")),
    k("macOS", "Aggiornamenti scaricati", "/Library/Updates", "Richiede privilegi di amministratore.", .safe, .manual("Serve sudo")),
    k("macOS", "Log di sistema", "/private/var/log", "Richiede privilegi di amministratore.", .safe, .manual("Serve sudo")),
    // Xcode
    k("Xcode", "DerivedData", "Library/Developer/Xcode/DerivedData", "Build intermedie: Xcode le ricrea.", .safe),
    k("Xcode", "iOS DeviceSupport", "Library/Developer/Xcode/iOS DeviceSupport", "Simboli di debug per dispositivi: si riscaricano al collegamento.", .safe),
    k("Xcode", "watchOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport", "Simboli di debug per Apple Watch.", .safe),
    k("Xcode", "Cache documentazione", "Library/Developer/Xcode/DocumentationCache", "Documentazione scaricata.", .safe),
    k("Xcode", "Simulatori non più disponibili", "Library/Developer/CoreSimulator", "Esegue `xcrun simctl delete unavailable`.", .safe, .command("xcrun simctl delete unavailable")),
    k("Xcode", "Archives", "Library/Developer/Xcode/Archives", "Archivi delle app pubblicate: contengono i dSYM, tienili se servono.", .caution, .manual("Gestisci da Xcode → Organizer")),
    // Sviluppo
    k("Sviluppo", "Cache npm", ".npm", "Pacchetti scaricati, si riscaricano.", .safe),
    k("Sviluppo", "Cache Yarn", ".yarn/cache", "Pacchetti scaricati.", .safe),
    k("Sviluppo", "pnpm store", ".pnpm-store", "Store condiviso: i progetti lo ricreeranno con un nuovo install.", .safe),
    k("Sviluppo", "~/.cache (pip, ecc.)", ".cache", "Cache varie di strumenti da riga di comando.", .safe),
    k("Sviluppo", "Gradle cache", ".gradle/caches", "Dipendenze scaricate, si riscaricano.", .safe),
    k("Sviluppo", "Maven repository", ".m2/repository", "Dipendenze scaricate, si riscaricano.", .safe),
    k("Sviluppo", "Cargo registry", ".cargo/registry", "Crate scaricati, si riscaricano.", .safe),
    k("Sviluppo", "CocoaPods", ".cocoapods", "Repository delle specs e cache.", .safe),
    k("Sviluppo", "Go modules", "go/pkg/mod", "Moduli scaricati (equivale a `go clean -modcache`).", .safe),
    k("Sviluppo", "Homebrew cache", "Library/Caches/Homebrew", "Esegue `brew cleanup -s --prune=all`. Incluso in “Cache utente”.", .safe, .command("export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; brew cleanup -s --prune=all")),
    k("Sviluppo", "Docker: immagini non usate", "Library/Containers/com.docker.docker/Data", "Esegue `docker system prune -a -f` (immagini/container non in uso; i volumi restano).", .caution, .command("export PATH=/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH; docker system prune -a -f")),
    k("Sviluppo", "Toolchain Rust", ".rustup/toolchains", "Toolchain installate: rimuovile con `rustup toolchain uninstall`.", .caution, .manual("Usa rustup")),
    k("Sviluppo", "Android SDK / AVD", "Library/Android/sdk", "Gestisci da Android Studio → SDK Manager.", .caution, .manual("Usa SDK Manager")),
    k("Sviluppo", "Emulatori Android", ".android/avd", "Dispositivi virtuali.", .caution, .manual("Usa AVD Manager")),
    k("Sviluppo", "Conda pkgs", "miniconda3/pkgs", "Usa `conda clean --all`.", .caution, .manual("conda clean --all")),
    k("Sviluppo", "Anaconda pkgs", "anaconda3/pkgs", "Usa `conda clean --all`.", .caution, .manual("conda clean --all")),
    // AI
    k("Modelli AI", "Modelli Ollama", ".ollama/models", "Modelli scaricati: elimina quelli che non usi con `ollama rm`.", .caution, .manual("ollama list / ollama rm")),
    k("Modelli AI", "Modelli HuggingFace", ".cache/huggingface", "Modelli e dataset scaricati.", .caution, .manual("Valuta cartella per cartella dalla Lista")),
    // App
    k("App", "Cache VS Code", "Library/Application Support/Code/CachedData", "Cache del codice compilato.", .safe),
    k("App", "Cache Slack", "Library/Application Support/Slack/Cache", "Cache dei media.", .safe),
    k("App", "Steam", "Library/Application Support/Steam", "Giochi installati.", .caution, .manual("Disinstalla dal client")),
    // Personali
    k("Personali", "Download", "Downloads", "Spesso pieno di installer e archivi: controlla nella Lista.", .caution, .manual("Valuta dalla Lista")),
    k("Personali", "Film", "Movies", "Video e progetti.", .caution, .manual("Valuta dalla Lista")),
]

enum SizeState: Equatable {
    case waiting, scanning, done(UInt64), denied, absent
}

@MainActor
final class WellKnownModel: ObservableObject {
    @Published var sizes: [String: SizeState] = [:]
    @Published var selected: Set<String> = []
    @Published var busy = false
    @Published var message = ""
    private var queue: [KnownItem] = []
    private var running = 0
    private var started = false

    func analyzeIfNeeded() { if !started { analyze() } }

    func analyze() {
        started = true
        sizes = [:]
        queue = knownItems
        for it in knownItems { sizes[it.id] = FileManager.default.fileExists(atPath: it.path) ? .waiting : .absent }
        queue.removeAll { sizes[$0.id] == .absent }
        pump()
    }

    private func pump() {
        while running < 3, !queue.isEmpty {
            let it = queue.removeFirst()
            measure(it)
        }
    }

    func measure(_ it: KnownItem) {
        running += 1
        sizes[it.id] = .scanning
        let sc = Scanner(path: it.path)
        sc.onFinish = { [weak self] in
            guard let self else { return }
            self.running -= 1
            self.sizes[it.id] = sc.root.denied && sc.root.size == 0 ? .denied : .done(sc.root.size)
            self.pump()
        }
        sc.start()
    }

    func exportTable() -> ExportTable {
        ExportTable(headers: ["Categoria", "Voce", "Rischio", "Percorso", "Byte", "Dimensione"],
                    rows: visible.map { [$0.category, $0.title, $0.risk == .safe ? "sicuro" : "attenzione", $0.path, String(size($0) ?? 0), size($0).map(formatBytes) ?? ""] })
    }

    func size(_ it: KnownItem) -> UInt64? { if case .done(let s) = sizes[it.id] { return s }; return nil }

    var visible: [KnownItem] { knownItems.filter { sizes[$0.id] != .absent && sizes[$0.id] != nil } }
    var selectedItems: [KnownItem] { visible.filter { selected.contains($0.id) && $0.cleanable } }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + (size($1) ?? 0) } }

    func selectSafe() {
        selected = Set(visible.filter { $0.risk == .safe && $0.cleanable && (size($0) ?? 0) > 0 && !$0.title.contains("Homebrew") }.map(\.id))
    }

    func reveal(_ it: KnownItem) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)]) }

    func clean(_ items: [KnownItem]) {
        guard !items.isEmpty, !busy else { return }
        let total = items.reduce(0) { $0 + (size($1) ?? 0) }
        if dryRunReport(count: items.count, bytes: total, detail: items.map { "• \($0.title)" }.joined(separator: "\n")) { return }
        let a = NSAlert()
        a.alertStyle = items.contains { $0.risk == .caution } ? .critical : .warning
        a.messageText = items.count == 1 ? "Pulire “\(items[0].title)”?" : "Pulire \(items.count) voci?"
        let list = items.map { "• \($0.title) — \(size($0).map(formatBytes) ?? "?")" }.joined(separator: "\n")
        a.informativeText = "\(list)\n\nLe cartelle verranno spostate nel Cestino (recuperabili), tranne Cestino e comandi che agiscono direttamente. Totale stimato: \(formatBytes(total))."
        a.addButton(withTitle: "Pulisci")
        a.addButton(withTitle: "Annulla")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }

        busy = true
        message = "Pulizia in corso…"
        let work = items
        DispatchQueue.global(qos: .userInitiated).async {
            var okCount = 0, fails: [String] = []
            var needTrash = false
            var log: [TrashEntry] = []
            for it in work {
                switch it.mode {
                case .contents:
                    let fm = FileManager.default
                    let kids = (try? fm.contentsOfDirectory(atPath: it.path)) ?? []
                    var failed = 0
                    for kid in kids {
                        do { try trashLogged(it.path + "/" + kid, &log) } catch { failed += 1 }
                    }
                    if failed > 0 { fails.append("\(it.title): \(failed) elementi in uso/protetti") } else { okCount += 1 }
                case .command(let cmd):
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    p.arguments = ["-c", cmd]
                    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                    do {
                        try p.run(); _ = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                        if p.terminationStatus == 0 { okCount += 1 } else { fails.append("\(it.title): comando fallito (\(p.terminationStatus))") }
                    } catch { fails.append("\(it.title): \(error.localizedDescription)") }
                case .emptyTrash: needTrash = true
                case .manual: break
                }
            }
            DispatchQueue.main.async { [self] in
                TrashLog.shared.record("WellKnown", log)
                let finish = { [self] in
                    busy = false
                    message = "Pulite \(okCount) voci" + (fails.isEmpty ? "" : " · \(fails.count) con problemi")
                    selected.subtract(work.map(\.id))
                    for it in work where it.cleanable { measure(it) }
                    if !fails.isEmpty {
                        let e = NSAlert(); e.messageText = "Alcune voci non sono state pulite"
                        e.informativeText = fails.joined(separator: "\n"); e.runModal()
                    }
                }
                if needTrash {
                    confirmAndEmptyTrash { ok in if ok { okCount += 1 } else { fails.append("Cestino: automazione Finder non consentita") }; finish() }
                } else { finish() }
            }
        }
    }
}

struct WellKnownView: View {
    @ObservedObject var wk: WellKnownModel
    let explore: (String) -> Void

    private var categories: [String] {
        var seen: [String] = []
        for it in wk.visible where !seen.contains(it.category) { seen.append(it.category) }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(categories, id: \.self) { cat in
                    Section(cat) {
                        let items = wk.visible.filter { $0.category == cat }.sorted { (wk.size($0) ?? 0) > (wk.size($1) ?? 0) }
                        ForEach(items) { row($0) }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Divider()
            HStack(spacing: 14) {
                Text(wk.message.isEmpty ? "Le voci possono sovrapporsi (es. Homebrew è dentro Cache utente)." : wk.message)
                Spacer()
                if !wk.selectedItems.isEmpty {
                    Text("\(wk.selectedItems.count) selezionate · ≈ \(formatBytes(wk.selectedBytes))").fontWeight(.medium)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onAppear { wk.analyzeIfNeeded() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { wk.analyze() } label: { Label("Rianalizza", systemImage: "arrow.clockwise") }
                Button { wk.selectSafe() } label: { Label("Seleziona sicure", systemImage: "checkmark.shield") }
                    .help("Seleziona le voci sicure e non vuote")
                Button { wk.clean(wk.selectedItems) } label: { Label("Pulisci selezionate", systemImage: "sparkles") }
                    .disabled(wk.selectedItems.isEmpty || wk.busy)
                Button { confirmAndEmptyTrash { _ in wk.analyze() } } label: { Label("Svuota Cestino", systemImage: "trash.slash") }
                GlobalToolbarButtons()
            }
        }
    }

    @ViewBuilder private func row(_ it: KnownItem) -> some View {
        HStack(spacing: 10) {
            if it.cleanable {
                Toggle("", isOn: Binding(get: { wk.selected.contains(it.id) },
                                         set: { if $0 { wk.selected.insert(it.id) } else { wk.selected.remove(it.id) } }))
                    .labelsHidden().toggleStyle(.checkbox)
            } else {
                Image(systemName: "hand.raised").foregroundStyle(.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(it.title).fontWeight(.medium)
                    Text(it.risk == .safe ? "sicuro" : "attenzione")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((it.risk == .safe ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                        .foregroundStyle(it.risk == .safe ? Color.green : Color.orange)
                }
                Text(it.note).font(.caption).foregroundStyle(.secondary)
                Text(it.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if case .manual(let hint) = it.mode { Text("Manuale: \(hint)").font(.caption2).foregroundStyle(.orange) }
            }
            Spacer()
            sizeLabel(it).frame(width: 90, alignment: .trailing)
            Button { wk.reveal(it) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Mostra nel Finder")
            Button { explore(it.path) } label: { Image(systemName: "list.bullet.indent") }.buttonStyle(.borderless).help("Esplora nella Lista")
            Button("Pulisci") { wk.clean([it]) }
                .disabled(!it.cleanable || wk.busy || (wk.size(it) ?? 0) == 0 && !isCommand(it))
        }
        .padding(.vertical, 3)
    }

    private func isCommand(_ it: KnownItem) -> Bool { if case .command = it.mode { return true }; return false }

    @ViewBuilder private func sizeLabel(_ it: KnownItem) -> some View {
        switch wk.sizes[it.id] ?? .waiting {
        case .done(let s): Text(formatBytes(s)).font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(s > 5 << 30 ? Color.red : s > 1 << 30 ? Color.orange : Color.primary)
        case .denied: Text("negato").foregroundStyle(.red).font(.caption)
        case .scanning: ProgressView().controlSize(.small)
        default: Text("…").foregroundStyle(.secondary)
        }
    }
}
