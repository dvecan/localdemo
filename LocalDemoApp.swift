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
                .tint(Brand.accent)
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
    /// Name shown on the card and on the password page. Empty means the folder name.
    @Published var customName: String { didSet { SiteStore.shared.save() } }
    /// Empty means no password. Saved in the app preferences (not encrypted).
    @Published var password: String { didSet { SiteStore.shared.save() } }
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var networkURL: String?
    @Published private(set) var requestCount = 0
    /// Short-lived note, e.g. when the chosen port was busy and another one was used.
    @Published private(set) var notice: String?

    private var process: Process?
    private var stderrBuffer = ""
    private var stoppedByUser = false

    init(folder: URL, port: String, password: String = "", name: String = "") {
        self.folder = folder
        self.portText = port
        self.password = password
        self.customName = name
    }

    var hasPassword: Bool { !password.isEmpty }

    var name: String { customName.isEmpty ? folder.lastPathComponent : customName }

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
        guard var port else { errorMessage = "El puerto debe ser un número entre 1024 y 65535."; return }

        // If the port is taken (by another folder here, another app or another user of this Mac),
        // move to the next free one instead of failing.
        let takenHere = { (p: Int) in SiteStore.shared.sites.contains { $0 !== self && $0.isRunning && $0.port == p } }
        if takenHere(port) || !PortProbe.isFree(port) {
            guard let free = PortProbe.firstFree(after: port, excluding: takenHere) else {
                errorMessage = "No hay puertos libres a partir del \(port)."
                return
            }
            showNotice("\(port) ocupado · usando \(free)")
            port = free
            portText = String(free)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // -I: isolated mode, so files in the served folder can't replace the Python modules the server imports.
        p.arguments = ["-I", "-u", "-c", LocalServer.script]
        var env = ProcessInfo.processInfo.environment
        env["LD_DIR"] = folder.path
        env["LD_PORT"] = String(port)
        env["LD_NAME"] = name
        env["LD_PASSWORD"] = password   // environment, not arguments: other users can't read it with `ps`
        p.environment = env
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
        notice = nil
    }

    private func showNotice(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
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
                return Site(folder: URL(fileURLWithPath: path), port: port, password: entry["password"] ?? "",
                            name: entry["name"] ?? "")
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
        UserDefaults.standard.set(sites.map { site -> [String: String] in
            var entry = ["path": site.folder.path, "port": site.portText]
            if site.hasPassword { entry["password"] = site.password }
            if !site.customName.isEmpty { entry["name"] = site.customName }
            return entry
        }, forKey: "sites")
    }

    /// Lowest port from 8000 not assigned to another folder and not in use on this Mac.
    private func nextFreePort() -> Int {
        let used = Set(sites.compactMap(\.port))
        return PortProbe.firstFree(after: 7999, excluding: { used.contains($0) }) ?? 8000
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

// MARK: - Port check

enum PortProbe {
    /// True when nothing on this Mac is listening on `port` and the server could bind it.
    static func isFree(_ port: Int) -> Bool {
        !answersOnLocalhost(port) && canBind(port)
    }

    /// First free port after `port` (up to 65535) that `excluding` doesn't reject.
    static func firstFree(after port: Int, excluding: (Int) -> Bool) -> Int? {
        guard port < 65535 else { return nil }
        return (max(port + 1, 1024)...65535).first { !excluding($0) && isFree($0) }
    }

    private static func address(_ port: Int, _ ip: in_addr_t) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: ip)
        return addr
    }

    /// Something (another app, or another user's server) already accepts connections there.
    private static func answersOnLocalhost(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(port, inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Same bind the Python server does (all interfaces, SO_REUSEADDR).
    private static func canBind(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = address(port, INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return bound && listen(fd, 1) == 0
    }
}

// MARK: - Web server (runs in /usr/bin/python3)

/// Small static server built on Python's http.server, with what the stock one lacks:
/// - optional password (login page + session cookie), with a pause after each wrong attempt
///   and a one-minute lock after 5 wrong attempts from the same device;
/// - never serves hidden files or folders (.git, .env, .DS_Store…) nor files outside the folder
///   through symbolic links;
/// - folder listings without hidden files; no caching, so devices always see the latest version.
/// Settings come from the environment: LD_DIR, LD_PORT, LD_NAME, LD_PASSWORD.
enum LocalServer {
    static let script = #"""
import hmac, html, io, os, re, secrets, sys, threading, time, urllib.parse
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.realpath(os.environ["LD_DIR"])
PORT = int(os.environ["LD_PORT"])
NAME = os.environ.get("LD_NAME", "Local Demo")
PASSWORD = os.environ.get("LD_PASSWORD", "")
COOKIE = "localdemo_%d" % PORT
LOGIN = "/__localdemo/login"
SESSIONS = set()
FAILS = {}
LOCK = threading.Lock()
SAFE_NEXT = re.compile(r"^/(?!/)[^\\\r\n]*$")

STYLE = """
:root{color-scheme:light dark;--bg:#fff;--card:#F3F1F1;--fg:#1d1d1f;--muted:#6e6e73;--field:#fff;--line:rgba(0,0,0,.12)}
@media (prefers-color-scheme:dark){:root{--bg:#1A1A1C;--card:#2A2A2D;--fg:#f5f5f7;--muted:#a1a1a6;--field:#1A1A1C;--line:rgba(255,255,255,.14)}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif}
.card{background:var(--card);border-radius:20px;padding:24px}
.label{font-size:12px;font-weight:500;color:var(--muted);margin:0 0 4px}
h1{font-size:20px;font-weight:600;margin:0 0 6px;overflow-wrap:anywhere}
p{margin:0 0 20px;color:var(--muted);font-size:14px}
a{color:inherit}
"""

LOGIN_PAGE = """<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{NAME}}</title><style>{{STYLE}}
body{min-height:100vh;display:grid;place-items:center;padding:16px}
form{width:100%;max-width:340px}
input{width:100%;font:inherit;padding:12px 14px;border-radius:12px;border:1px solid var(--line);background:var(--field);color:var(--fg)}
button{margin-top:12px;width:100%;font:inherit;font-weight:600;padding:12px;border:0;border-radius:999px;background:#D94870;color:#fff;cursor:pointer}
.error{color:#e5484d;font-size:13px;margin:10px 0 0}
</style></head><body>
<form class="card" method="post" action="/__localdemo/login">
<div class="label">Protegida con contraseña</div>
<h1>{{NAME}}</h1>
<p>Escribe la contraseña para ver esta web.</p>
<input type="password" name="password" placeholder="Contraseña" aria-label="Contraseña" autocomplete="current-password" autofocus required>
<input type="hidden" name="next" value="{{NEXT}}">
{{ERROR}}
<button type="submit">Entrar</button>
</form></body></html>"""

LIST_PAGE = """<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{TITLE}}</title><style>{{STYLE}}
body{padding:32px 16px}
.card{max-width:640px;margin:0 auto}
ul{list-style:none;margin:0;padding:0}
li a{display:block;padding:10px 0;border-top:1px solid var(--line);text-decoration:none;overflow-wrap:anywhere}
</style></head><body><div class="card">
<div class="label">{{NAME}}</div>
<h1>{{TITLE}}</h1>
<p>{{COUNT}}</p>
<ul>{{ITEMS}}</ul>
</div></body></html>"""


def fill(template, **values):
    out = template.replace("{{STYLE}}", STYLE)
    for key, value in values.items():
        out = out.replace("{{%s}}" % key, value)
    return out


class Handler(SimpleHTTPRequestHandler):
    server_version = "LocalDemo"
    sys_version = ""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        super().end_headers()

    # Access control

    def signed_in(self):
        if not PASSWORD:
            return True
        for part in self.headers.get("Cookie", "").split(";"):
            key, _, value = part.strip().partition("=")
            if key == COOKIE and value in SESSIONS:
                return True
        return False

    def forbidden_path(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        if any(part.startswith(".") for part in path.split("/")):
            return True
        real = os.path.realpath(self.translate_path(self.path))
        return not (real == ROOT or real.startswith(ROOT + os.sep))

    def allowed(self):
        if not self.signed_in():
            self.login_page(HTTPStatus.UNAUTHORIZED, "", self.path)
            return False
        if self.forbidden_path():
            self.send_error(HTTPStatus.NOT_FOUND, "No encontrado")
            return False
        return True

    def do_GET(self):
        if self.allowed():
            super().do_GET()

    def do_HEAD(self):
        if self.allowed():
            super().do_HEAD()

    def do_POST(self):
        if not PASSWORD or urllib.parse.urlsplit(self.path).path != LOGIN:
            self.send_error(HTTPStatus.METHOD_NOT_ALLOWED)
            return
        try:
            length = min(int(self.headers.get("Content-Length") or 0), 4096)
        except ValueError:
            length = 0
        form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        given = form.get("password", [""])[0]
        target = form.get("next", ["/"])[0]
        if not SAFE_NEXT.match(target):
            target = "/"

        ip = self.client_address[0]
        with LOCK:
            count, until = FAILS.get(ip, (0, 0))
        if time.time() < until:
            self.login_page(HTTPStatus.TOO_MANY_REQUESTS, "Demasiados intentos. Espera un minuto.", target)
            return

        if hmac.compare_digest(given.encode("utf-8"), PASSWORD.encode("utf-8")):
            token = secrets.token_urlsafe(32)
            with LOCK:
                FAILS.pop(ip, None)
                SESSIONS.add(token)
            self.send_response(HTTPStatus.SEE_OTHER)
            self.send_header("Location", target)
            self.send_header("Set-Cookie", "%s=%s; Path=/; HttpOnly; SameSite=Lax" % (COOKIE, token))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        count += 1
        with LOCK:
            FAILS[ip] = (0, time.time() + 60) if count >= 5 else (count, 0)
        time.sleep(1)
        self.login_page(HTTPStatus.UNAUTHORIZED, "Contraseña incorrecta.", target)

    def login_page(self, status, error, target):
        if not SAFE_NEXT.match(target):
            target = "/"
        body = fill(LOGIN_PAGE,
                    NAME=html.escape(NAME),
                    NEXT=html.escape(target, quote=True),
                    ERROR='<p class="error" role="alert">%s</p>' % html.escape(error) if error else "")
        # Browsers may keep copies saved while this address was public (e.g. by an earlier version
        # or a run without password) and show them without asking. Tell them to drop those copies.
        self.send_html(status, body, {"Clear-Site-Data": '"cache"'})

    def send_html(self, status, body, extra_headers=None):
        data = body.encode("utf-8")
        self.send_response(status)
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    # Folder listing without hidden files

    def list_directory(self, path):
        try:
            names = sorted((n for n in os.listdir(path) if not n.startswith(".")
                            and os.path.realpath(os.path.join(path, n)).startswith(ROOT + os.sep)), key=str.lower)
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND, "No encontrado")
            return None
        shown = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        items = []
        if shown != "/":
            items.append('<li><a href="../">↑ Carpeta superior</a></li>')
        for name in names:
            label = name + ("/" if os.path.isdir(os.path.join(path, name)) else "")
            items.append('<li><a href="%s">%s</a></li>' % (urllib.parse.quote(label), html.escape(label)))
        count = "%d %s" % (len(names), "elemento" if len(names) == 1 else "elementos")
        data = fill(LIST_PAGE, NAME=html.escape(NAME), TITLE=html.escape(shown),
                    COUNT=count, ITEMS="".join(items)).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        return io.BytesIO(data)


def stop_with_app(parent=os.getppid()):
    # If Local Demo quits unexpectedly (crash, force quit), don't keep the folder open on the network.
    while os.getppid() == parent:
        time.sleep(2)
    os._exit(0)


threading.Thread(target=stop_with_app, daemon=True).start()
ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
"""#
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
    /// Smaller version for popovers, same height as a text field.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 5 : 8)
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

/// Text link in the CTA colour (instead of the system blue).
struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(Brand.accent)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Text field with a neutral border that turns the CTA colour while typing (instead of the blue focus ring).
struct BrandField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(focused ? Brand.accent : Color.secondary.opacity(0.3), lineWidth: focused ? 1.5 : 1))
            .tint(Brand.accent)
            .onAppear { DispatchQueue.main.async { focused = true } }
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

/// Tall rounded card with a flat warm-grey background; on hover it lifts 2 pt with a faint shadow.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        content()
            .frame(width: ContentView.cardSize.width, height: ContentView.cardSize.height)
            .background(Brand.card, in: shape)
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
    @State private var editingPassword = false
    @State private var showQR = false
    @State private var portDraft = ""
    @State private var passwordDraft = ""
    @State private var editingName = false
    @State private var nameDraft = ""
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
            Button("Cambiar nombre…", action: renameSite)
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) }
            Button("Cambiar carpeta…", action: changeFolder).disabled(site.isRunning)
            Divider()
            Button("Quitar de la lista") { SiteStore.shared.remove(site) }.disabled(site.isRunning)
        }
    }

    private func topRow() -> some View {
        HStack(spacing: 8) {
            Image(systemName: site.isRunning ? "dot.radiowaves.left.and.right" : "folder")
                .font(.system(size: 15, weight: .regular))
            if site.hasPassword {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Protegida con contraseña")
                    .accessibilityLabel("Protegida con contraseña")
            }
            Spacer()
            if !site.isRunning {
                Menu {
                    Button("Cambiar nombre…", action: renameSite)
                    Button("Cambiar puerto…") { portDraft = site.portText; editingPort = true }
                    Button(site.hasPassword ? "Cambiar contraseña…" : "Poner contraseña…") {
                        passwordDraft = site.password; editingPassword = true
                    }
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
        .popover(isPresented: $editingPassword, arrowEdge: .bottom) { passwordEditor }
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
            QRPopover(url: url, visits: site.requestCount, password: site.password)
        }
    }

    /// Label, title and description at the bottom-left, as in the reference; action below.
    private func bottom() -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            if site.isRunning {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(site.notice ?? "Activa · \(site.requestCount) \(site.requestCount == 1 ? "visita" : "visitas")")
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
                .help("\(site.folder.path)\nDoble clic para cambiar el nombre")
                .onTapGesture(count: 2, perform: renameSite)
                .popover(isPresented: $editingName, arrowEdge: .bottom) { nameEditor }

            description()

            HStack(spacing: 8) {
                if site.isRunning {
                    Button("Detener") { site.stop() }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                    if let url = site.shareURL, let link = URL(string: url) {
                        // Opens the site in the default browser.
                        Button { open(url) } label: {
                            circleIcon("display")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .help("Abrir en el navegador")
                        .accessibilityLabel("Abrir en el navegador")

                        // Native macOS share menu (AirDrop, Mensajes, Mail, Notas…) with the address.
                        ShareLink(item: link) {
                            circleIcon("square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .help("Compartir dirección")
                        .accessibilityLabel("Compartir dirección")
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

    /// Round grey icon button face, same height as the pill buttons.
    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(Brand.pillFill, in: Circle())
            .contentShape(Circle())
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
            // Click the address to copy it; it briefly confirms in place.
            let shown = (site.networkURL ?? site.shareURL ?? "").replacingOccurrences(of: "http://", with: "")
            Button {
                if let url = site.shareURL { copy(url) }
            } label: {
                Group {
                    if copied {
                        Label("URL en el portapapeles", systemImage: "checkmark")
                    } else {
                        Text(shown).monospacedDigit()
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: copied)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Copiar dirección")
            .accessibilityLabel("Copiar dirección \(shown)")
        } else {
            // With a custom name, include the folder itself so it's still clear what is served.
            let shownFolder = site.customName.isEmpty ? site.folder.deletingLastPathComponent() : site.folder
            Text((shownFolder.path as NSString).abbreviatingWithTildeInPath)
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
                BrandField(placeholder: "8000", text: $portDraft, onSubmit: applyPort)
                    .frame(width: 80)
                Button("Aceptar", action: applyPort)
                    .buttonStyle(PillButtonStyle(kind: .prominent, compact: true))
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
        return Array((8000...8099).lazy.filter { !used.contains($0) && PortProbe.isFree($0) }.prefix(4))
    }

    private var passwordEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Contraseña").font(.headline)
            Text("Quien abra la web tendrá que escribirla.\nNo uses una contraseña personal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                BrandField(placeholder: "Sin contraseña", text: $passwordDraft, onSubmit: applyPassword)
                    .frame(width: 150)
                Button("Aceptar", action: applyPassword)
                    .buttonStyle(PillButtonStyle(kind: .prominent, compact: true))
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 12) {
                Button("Generar") { passwordDraft = Self.randomPassword() }
                if site.hasPassword {
                    Button("Quitar contraseña") { passwordDraft = ""; applyPassword() }
                }
            }
            .buttonStyle(LinkStyle())
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private func renameSite() {
        nameDraft = site.customName
        editingName = true
    }

    var nameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nombre").font(.headline)
            HStack(spacing: 8) {
                BrandField(placeholder: site.folder.lastPathComponent, text: $nameDraft, onSubmit: applyName)
                    .frame(width: 180)
                Button("Aceptar", action: applyName)
                    .buttonStyle(PillButtonStyle(kind: .prominent, compact: true))
                    .keyboardShortcut(.defaultAction)
            }
            if !site.customName.isEmpty {
                Button("Usar el nombre de la carpeta") { nameDraft = ""; applyName() }
                    .buttonStyle(LinkStyle())
            }
        }
        .padding(14)
    }

    private func applyName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        site.customName = trimmed == site.folder.lastPathComponent ? "" : trimmed
        editingName = false
    }

    private func applyPassword() {
        site.password = passwordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingPassword = false
    }

    /// Easy to read aloud or type on a phone: 3 groups of 4 letters/digits without look-alikes.
    static func randomPassword() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return (0..<3).map { _ in String((0..<4).map { _ in chars.randomElement()! }) }.joined(separator: "-")
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
    var password = ""

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
                if !password.isEmpty {
                    Label("Contraseña: \(password)", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
        }
        .padding(20)
    }
}
