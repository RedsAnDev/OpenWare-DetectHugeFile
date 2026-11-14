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

import SwiftUI

struct DetectHugeFileApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
    var body: some Scene {
        WindowGroup("DetectHugeFile", id: "main") {
            ContentView().frame(minWidth: 1000, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 780)
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case lista = "Lista", mappa = "Mappa", wellKnown = "WellKnown", artefatti = "Artefatti"
    case duplicati = "Duplicati", container = "Container", homebrew = "Homebrew", storico = "Storico", sistema = "Sistema"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var wk = WellKnownModel()
    @StateObject private var art = ArtifactModel()
    @StateObject private var dup = DuplicatesModel()
    @StateObject private var sys = SystemModel()
    @StateObject private var cont = ContainersModel()
    @StateObject private var brew = BrewModel()
    @ObservedObject private var hist = HistoryModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var tab: Tab = .lista

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .lista: ListaView(model: model)
                case .mappa: MappaView(model: model)
                case .wellKnown: WellKnownView(wk: wk) { path in model.scan(path: path); tab = .lista }
                case .artefatti: ArtefattiView(art: art) { path in model.scan(path: path); tab = .lista }
                case .duplicati: DuplicatiView(dup: dup)
                case .container: ContainerView(cont: cont)
                case .homebrew: HomebrewView(brew: brew)
                case .storico: StoricoView(hist: hist)
                case .sistema: SistemaView(sys: sys)
                }
            }
            if !settings.toast.isEmpty {
                Text(settings.toast).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).shadow(radius: 4).padding(.bottom, 40)
            }
        }
        // Le tab restano al centro; tutte le icone vivono nei gruppi `.primaryAction` delle singole viste (a destra).
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Vista", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 700)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(settings.dryRun ? "MODALITÀ A SECCO" : "")
        .onAppear { updateExport() }
        .onChange(of: tab) { _ in updateExport() }
    }

    private var title: String {
        switch tab {
        case .lista, .mappa: return model.root?.path ?? "DetectHugeFile"
        case .wellKnown: return "Colpevoli noti"
        case .artefatti: return "Artefatti di progetto"
        case .duplicati: return "File duplicati"
        case .container: return "Docker · Podman · minikube"
        case .homebrew: return "Homebrew"
        case .storico: return "Storico e confronto"
        case .sistema: return "Simulatori, backup, snapshot"
        }
    }

    private func updateExport() {
        let t = tab
        settings.exportProvider = { [model, wk, art, dup, cont, brew, hist, sys] in
            switch t {
            case .lista, .mappa: return ("cartelle", model.exportTable())
            case .wellKnown: return ("colpevoli-noti", wk.exportTable())
            case .artefatti: return ("artefatti", art.exportTable())
            case .duplicati: return ("duplicati", dup.exportTable())
            case .container: return ("container", cont.exportTable())
            case .homebrew: return ("homebrew", brew.exportTable())
            case .storico: return ("confronto", hist.exportTable())
            case .sistema: return ("sistema", sys.exportTable())
            }
        }
    }
}

struct ListaView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.fdaMissing {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Senza l'Accesso completo al disco alcune cartelle (Mail, Safari, Cestino, backup) risultano “accesso negato”.")
                    Spacer()
                    Button("Apri Impostazioni") { AppModel.openFullDiskAccessSettings() }
                    Button { model.fdaMissing = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
            ZStack {
                FolderOutline(model: model)
                if model.scanning {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Scansione in corso…").font(.headline)
                        Text(model.progress).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).frame(maxWidth: 560)
                        Button("Annulla") { model.cancelScan() }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Cartella Home") { model.scan(path: NSHomeDirectory()) }
                    Button("Scegli cartella…") { model.chooseFolder() }
                    Divider()
                    VolumeMenuItems { model.scan(path: $0) }
                } label: { Label("Cartella", systemImage: "folder") }
                    .help("Scansiona la home, una cartella o un disco (anche USB)")
                Button { model.rescan() } label: { Label("Riscansiona", systemImage: "arrow.clockwise") }
                    .disabled(model.scanning || model.root == nil)
                Toggle(isOn: $model.flatToggle) { Label("Elenco piatto", systemImage: "list.bullet") }
                    .help("Elenco piatto di tutte le cartelle, ordinabile per dimensione")
                Toggle(isOn: $model.showFiles) { Label("File grandi", systemImage: "doc") }
                    .help("Mostra anche i singoli file ≥ 10 MB")
                Picker("Soglia", selection: $model.minSizeMB) {
                    Text("Tutte").tag(0)
                    Text("≥ 10 MB").tag(10)
                    Text("≥ 100 MB").tag(100)
                    Text("≥ 500 MB").tag(500)
                    Text("≥ 1 GB").tag(1024)
                    Text("≥ 5 GB").tag(5120)
                }
                .help("Soglia minima (elenco piatto)")
                Button { model.emptyTrash() } label: { Label("Svuota Cestino", systemImage: "trash.slash") }
                Button(role: .destructive) { model.trashSelection() } label: { Label("Sposta nel Cestino", systemImage: "trash") }
                    .disabled(model.selection.isEmpty)
                    .keyboardShortcut(.delete, modifiers: .command)
                GlobalToolbarButtons()
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Cerca cartelle e file")
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if !model.selection.isEmpty {
                Text("\(model.selection.count) selezionati · \(formatBytes(model.selection.reduce(0) { $0 + $1.size }))")
                    .fontWeight(.medium)
            } else {
                Text(model.status)
            }
            Spacer()
            if let r = model.root { Text("Totale scansione: \(formatBytes(r.size))") }
            Text("Libero: \(formatBytes(model.freeSpace))")
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct MenuBarLabel: View {
    @ObservedObject private var disk = DiskMonitor.shared
    var body: some View {
        HStack(spacing: 4) { Image(systemName: "internaldrive"); Text(formatBytes(disk.free)) }
    }
}

struct MenuBarContent: View {
    @ObservedObject private var disk = DiskMonitor.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Spazio libero: \(formatBytes(disk.free))")
        if !disk.external.isEmpty {
            Divider()
            ForEach(disk.external) { v in
                Text("\(v.name): \(formatBytes(v.free)) liberi di \(formatBytes(v.total))")
                if v.ejectable { Button("Espelli “\(v.name)”") { disk.eject(v) } }
            }
        }
        Divider()
        Button("Apri DetectHugeFile") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Button("Svuota Cestino…") { confirmAndEmptyTrash { _ in DiskMonitor.shared.update() } }
        Button("Aggiorna") { disk.update() }
        Divider()
        Button("Esci") { NSApp.terminate(nil) }
    }
}
