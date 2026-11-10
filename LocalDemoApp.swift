import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - App

@main
struct LocalDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SiteStore.shared

    var body: some Scene {
        Window("Local Demo", id: "main") {
            ContentView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SiteStore.shared.stopAll() }
    }
}

// MARK: - Site (one folder served on one port)

@MainActor
final class Site: ObservableObject, Identifiable {
    let id = UUID()

    @Published var folder: URL { didSet { SiteStore.shared.save() } }
    @Published var portText: String { didSet { SiteStore.shared.save() } }
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var networkURL: String?
    @Published private(set) var requestCount = 0

    private var process: Process?
    private var stderrBuffer = ""
    private var stoppedByUser = false

    init(folder: URL, port: String) {
        self.folder = folder
        self.portText = port
    }

    var name: String { folder.lastPathComponent }

    var port: Int? {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p) else { return nil }
        return p
    }

    /// Address to open on this Mac or share: the network one when there is a network.
    var shareURL: String? { networkURL ?? port.map { "http://localhost:\($0)" } }

    func start() {
        errorMessage = nil
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            errorMessage = "La carpeta ya no existe. Elige otra desde el menú «…»."
            return
        }
        guard let port else { errorMessage = "El puerto debe ser un número entre 1024 y 65535."; return }
        if SiteStore.shared.sites.contains(where: { $0 !== self && $0.isRunning && $0.port == port }) {
            errorMessage = "Otra carpeta ya usa el puerto \(port)."
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-u", "-m", "http.server", String(port), "--bind", "0.0.0.0", "--directory", folder.path]
        p.currentDirectoryURL = folder

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        stderrBuffer = ""
        requestCount = 0

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stderrBuffer += text
                if self.stderrBuffer.count > 20_000 { self.stderrBuffer = String(self.stderrBuffer.suffix(5_000)) }
                // http.server logs each request to stderr as: ... "GET /path HTTP/1.1" 200 -
                self.requestCount += text.components(separatedBy: "\" ").count - 1
            }
        }

        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.isRunning = false
                self.process = nil
                if !self.stoppedByUser && status != 0 {
                    self.errorMessage = self.friendlyError(from: self.stderrBuffer)
                }
                self.stoppedByUser = false
            }
        }

        do {
            stoppedByUser = false
            try p.run()
            process = p
            isRunning = true
            networkURL = SiteStore.localIPAddress().map { "http://\($0):\(port)" }
        } catch {
            errorMessage = "No se pudo iniciar el servidor: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        stoppedByUser = true
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        isRunning = false
    }

    private func friendlyError(from stderr: String) -> String {
        if stderr.contains("Address already in use") {
            return "El puerto \(portText) ya está en uso por otra app. Prueba con otro."
        }
        if stderr.contains("Permission denied") {
            return "Sin permiso para usar ese puerto o carpeta."
        }
        if stderr.contains("xcode-select") || stderr.contains("developer tools") {
            return "Falta python3. Instala las Command Line Tools con: xcode-select --install"
        }
        let lastLine = stderr.split(separator: "\n").last.map(String.init) ?? "Error desconocido"
        return "El servidor se ha detenido: \(lastLine)"
    }
}

// MARK: - Store (all sites, persisted)

@MainActor
final class SiteStore: ObservableObject {
    static let shared = SiteStore()

    @Published private(set) var sites: [Site] = []

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: "sites") as? [[String: String]] {
            sites = saved.compactMap { entry in
                guard let path = entry["path"], let port = entry["port"] else { return nil }
                return Site(folder: URL(fileURLWithPath: path), port: port)
            }
        } else if let path = defaults.string(forKey: "folder"),
                  FileManager.default.fileExists(atPath: path) {
            // Migrate the single folder saved by earlier versions.
            sites = [Site(folder: URL(fileURLWithPath: path), port: defaults.string(forKey: "port") ?? "8000")]
            defaults.removeObject(forKey: "folder")
            defaults.removeObject(forKey: "port")
            save()
        }

        // Used by build verification: start serving every saved folder immediately.
        if ProcessInfo.processInfo.environment["LOCALDEMO_AUTOSTART"] == "1" {
            DispatchQueue.main.async { self.sites.forEach { $0.start() } }
        }
    }

    func add(_ folders: [URL]) {
        for folder in folders where folder.hasDirectoryPath {
            let standard = folder.standardizedFileURL
            guard !sites.contains(where: { $0.folder.standardizedFileURL == standard }) else { continue }
            sites.append(Site(folder: folder, port: String(nextFreePort())))
        }
        save()
    }

    func remove(_ site: Site) {
        site.stop()
        sites.removeAll { $0 === site }
        save()
    }

    func stopAll() { sites.forEach { $0.stop() } }

    /// Stops every server and empties the list.
    func removeAll() {
        stopAll()
        sites.removeAll()
        save()
    }

    func save() {
        UserDefaults.standard.set(sites.map { ["path": $0.folder.path, "port": $0.portText] }, forKey: "sites")
    }

    private func nextFreePort() -> Int {
        let used = Set(sites.compactMap(\.port))
        var port = 8000
        while used.contains(port) { port += 1 }
        return port
    }

    /// Returns the Mac's IPv4 address on the local network (Wi‑Fi/Ethernet first).
    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: ptr.pointee.ifa_name)
            if ip.hasPrefix("169.254.") { continue }
            candidates.append((name, ip))
        }
        let preferred = candidates.first { $0.name == "en0" }
            ?? candidates.first { $0.name.hasPrefix("en") }
            ?? candidates.first { !$0.name.hasPrefix("utun") && !$0.name.hasPrefix("bridge") }
            ?? candidates.first
        return preferred?.ip
    }
}

// MARK: - QR

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

// MARK: - Style

/// Colours taken from the app logo, plus the surfaces of the carousel layout.
enum Brand {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Colour of the main call to action (Iniciar / Elegir). The only coloured element in the UI.
    static let accent = Color(nsColor: hex(0xD94870))
    static let onAccent = Color.white

    /// White page with warm light-grey cards, as in the reference.
    static let canvas = adaptive(light: .white, dark: hex(0x1A1A1C))
    static let card = adaptive(light: hex(0xF3F1F1), dark: hex(0x2A2A2D))

    /// Neutral fill for secondary pills and controls.
    static let pillFill = adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.10))
}

/// Rounded pill button: accent fill for the main action, neutral grey otherwise.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case prominent, neutral }
    var kind: Kind = .prominent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .foregroundStyle(kind == .prominent ? Brand.onAccent : Color.primary)
            .background(background, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }

    private var background: Color {
        switch kind {
        case .prominent: return Brand.accent
        case .neutral: return Brand.pillFill
        }
    }
}

// MARK: - Main window: header + horizontal carousel of tall cards

struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    @State private var isDropTarget = false
    @State private var confirmClear = false
    @State private var scrollTarget: UUID?

    static let cardSize = CGSize(width: 220, height: 350)
    static let windowWidth: CGFloat = 760
    static let cardSpacing: CGFloat = 14
    static let sideMargin: CGFloat = 32

    private var runningCount: Int { store.sites.filter(\.isRunning).count }

    /// True when the folder cards don't all fit beside the pinned "Add" card, so arrows are useful.
    private var needsArrows: Bool {
        let n = CGFloat(store.sites.count)
        guard n > 0 else { return false }
        let visible = Self.windowWidth - Self.sideMargin - Self.cardSize.width - Self.cardSpacing
        let content = n * Self.cardSize.width + (n - 1) * Self.cardSpacing + Self.sideMargin
        return content > visible
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            carousel
            footer
        }
        .padding(.top, 44)       // room for the window buttons (hidden title bar)
        .padding(.bottom, 24)
        .frame(width: Self.windowWidth)
        .background(Brand.canvas)
        .overlay {
            // Neutral dashed outline while dragging folders over the window (no colour change).
            if isDropTarget {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .padding(10)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath)
            guard !folders.isEmpty else { return false }
            add(folders)
            return true
        } isTargeted: { isDropTarget = $0 }
        .confirmationDialog("¿Quitar todas las carpetas?", isPresented: $confirmClear) {
            Button("Quitar y detener", role: .destructive) { store.removeAll() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(runningCount == 1
                 ? "Hay 1 servidor activo y se detendrá. Las carpetas no se borran del disco."
                 : "Hay \(runningCount) servidores activos y se detendrán. Las carpetas no se borran del disco.")
        }
        .onAppear {
            DispatchQueue.main.async {
                for window in NSApp.windows { window.makeFirstResponder(nil) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tus proyectos, en cualquier dispositivo local")
                    .font(.system(size: 26, weight: .semibold))
                Text("Arrastra carpetas a esta ventana y visualízalas en cualquier dispositivo conectado a este wifi.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if needsArrows {
                HStack(spacing: 8) {
                    arrowButton("chevron.left") { step(-1) }
                    arrowButton("chevron.right") { step(1) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 32)
    }

    private func arrowButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Brand.pillFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var carousel: some View {
        // "Add folder" stays pinned on the left; only the folder cards scroll.
        HStack(spacing: 0) {
            AddCard(onChoose: chooseFolders)
                .padding(.leading, 32)
                .padding(.trailing, 14)
                .padding(.vertical, 24)   // room for the hover lift and shadow

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(store.sites) { site in
                        SiteCard(site: site)
                            .id(site.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .scrollTargetLayout()
                .padding(.trailing, 32)
                .padding(.vertical, 24)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollTarget, anchor: .leading)
        }
        .frame(height: Self.cardSize.height + 48)
        .animation(.easeOut(duration: 0.25), value: store.sites.map(\.id))
    }

    private var footer: some View {
        HStack {
            Text(summary)
            Spacer()
            if !store.sites.isEmpty {
                Button("Limpiar") {
                    if runningCount > 0 { confirmClear = true } else { store.removeAll() }
                }
                .buttonStyle(.plain)
                .help("Quitar todas las carpetas")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)
    }

    private var summary: String {
        let total = store.sites.count
        if total == 0 { return "Sin carpetas todavía" }
        let folders = total == 1 ? "1 carpeta" : "\(total) carpetas"
        return runningCount == 0 ? folders : "\(folders) · \(runningCount) \(runningCount == 1 ? "activa" : "activas")"
    }

    private var orderedIDs: [UUID] { store.sites.map(\.id) }

    private func step(_ delta: Int) {
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        let current = scrollTarget.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = max(0, min(ids.count - 1, current + delta))
        withAnimation(.easeInOut(duration: 0.3)) { scrollTarget = ids[next] }
    }

    private func add(_ folders: [URL]) {
        let before = store.sites.count
        store.add(folders)
        if store.sites.count > before {
            let id = store.sites[before].id
            DispatchQueue.main.async { withAnimation { scrollTarget = id } }
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Añadir"
        panel.message = "Elige una o varias carpetas con tu web (por ejemplo, las que tienen un index.html)"
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

// MARK: - Card shell

/// Tall rounded card with a flat warm-grey background that never changes colour;
/// on hover it lifts 2 pt with a faint shadow.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let fill = Brand.card   // backgrounds never change colour; only the CTA carries colour

        content()
            .frame(width: ContentView.cardSize.width, height: ContentView.cardSize.height)
            .background(fill, in: shape)
            .clipShape(shape)
            .offset(y: hovering ? -2 : 0)
            .shadow(color: .black.opacity(hovering ? 0.05 : 0), radius: 12, y: 6)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.25), value: hovering)
    }
}

// MARK: - One card per folder

struct SiteCard: View {
    @ObservedObject var site: Site
    @State private var editingPort = false
    @State private var showQR = false
    @State private var portDraft = ""
    @State private var copied = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                topRow()
                Spacer(minLength: 0)
                if site.isRunning, let url = site.networkURL {
                    qrTile(url)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                bottom()
            }
            .padding(16)
        }
        .contextMenu {
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) }
            Button("Cambiar carpeta…", action: changeFolder).disabled(site.isRunning)
            Divider()
            Button("Quitar de la lista") { SiteStore.shared.remove(site) }.disabled(site.isRunning)
        }
    }

    private func topRow() -> some View {
        HStack {
            Image(systemName: site.isRunning ? "dot.radiowaves.left.and.right" : "folder")
                .font(.system(size: 15, weight: .regular))
            Spacer()
            if !site.isRunning {
                Menu {
                    Button("Cambiar puerto…") { portDraft = site.portText; editingPort = true }
                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) }
                    Button("Cambiar carpeta…", action: changeFolder)
                    Divider()
                    Button("Quitar de la lista") { SiteStore.shared.remove(site) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Opciones")
                .popover(isPresented: $editingPort, arrowEdge: .bottom) { portEditor }
            }
        }
        .foregroundStyle(.primary)
        .frame(height: 30)
    }

    private func qrTile(_ url: String) -> some View {
        Button { showQR = true } label: {
            if let qr = QRCode.image(for: url) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
        }
        .buttonStyle(.plain)
        .help("Ampliar código QR")
        .popover(isPresented: $showQR, arrowEdge: .bottom) {
            QRPopover(url: url, visits: site.requestCount)
        }
    }

    /// Label, title and description at the bottom-left, as in the reference; action below.
    private func bottom() -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            if site.isRunning {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Activa · \(site.requestCount) \(site.requestCount == 1 ? "visita" : "visitas")")
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            } else {
                Button { portDraft = site.portText; editingPort = true } label: {
                    Text("Puerto \(site.portText)")
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Cambiar puerto")
            }

            Text(site.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .help(site.folder.path)

            description()

            HStack(spacing: 8) {
                if site.isRunning {
                    Button("Detener") { site.stop() }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                    if let url = site.shareURL {
                        // Opens the site in the default browser.
                        Button { open(url) } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background(Brand.pillFill, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .help("Abrir en el navegador")
                        .accessibilityLabel("Abrir en el navegador")
                    }
                } else {
                    Button("Iniciar") { site.start() }
                        .buttonStyle(PillButtonStyle(kind: .prominent))
                        .disabled(site.port == nil)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func description() -> some View {
        if let error = site.errorMessage, !site.isRunning {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else if site.isRunning {
            Menu {
                if let url = site.shareURL {
                    Button(copied ? "Copiada" : "Copiar dirección") { copy(url) }
                    Button("Abrir en el navegador") { open(url) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text((site.networkURL ?? site.shareURL ?? "").replacingOccurrences(of: "http://", with: ""))
                        .monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copiar o abrir la dirección")
        } else {
            Text((site.folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
        }
    }

    private var portEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Puerto").font(.headline)
            HStack(spacing: 8) {
                TextField("8000", text: $portDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit(applyPort)
                Button("Aceptar", action: applyPort)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Libres: " + suggestedPorts.prefix(4).map(String.init).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var suggestedPorts: [Int] {
        let used = Set(SiteStore.shared.sites.filter { $0 !== site }.compactMap(\.port))
        return (8000...8099).filter { !used.contains($0) }
    }

    private func applyPort() {
        site.portText = portDraft.trimmingCharacters(in: .whitespaces)
        editingPort = false
    }

    private func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Elegir"
        panel.directoryURL = site.folder
        if panel.runModal() == .OK, let url = panel.url { site.folder = url }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Last card: add folders

struct AddCard: View {
    var onChoose: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .regular))
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nueva")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Añadir carpeta")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Arrástrala a la ventana o elígela desde Finder.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Elegir", action: onChoose)
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                        .padding(.top, 8)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onTapGesture(perform: onChoose)
    }
}

struct QRPopover: View {
    let url: String
    let visits: Int

    var body: some View {
        VStack(spacing: 12) {
            if let qr = QRCode.image(for: url) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 176, height: 176)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Código QR de \(url)")
            }
            VStack(spacing: 3) {
                Text(url.replacingOccurrences(of: "http://", with: ""))
                    .font(.system(size: 15, weight: .bold))
                    .textSelection(.enabled)
                Text("Escanéalo con el móvil · \(visits) \(visits == 1 ? "visita" : "visitas")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(20)
    }
}
