import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - App

@main
struct LocalDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SiteStore.shared
    @StateObject private var panels = Panels.shared

    var body: some Scene {
        Window("Local Demo", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(panels)
                .tint(Brand.accent)
                .focusEffectDisabled()   // our pink focus ring replaces the system's blue one
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Help menu: the tour can be seen again at any time, after skipping or finishing it.
            CommandGroup(replacing: .help) {
                Button(tr("Recorrido por Local Demo", ca: "Recorregut per Local Demo", en: "Local Demo Tour")) { panels.show(.tour) }
                Button(tr("¿Qué carpeta elijo?", ca: "Quina carpeta trio?", en: "Which Folder Should I Choose?")) { panels.show(.folderHelp) }
            }
        }
    }
}

/// The panel shown over the main window, if any. Shared so the Help menu can open them.
@MainActor
final class Panels: ObservableObject {
    enum Kind { case tour, folderHelp }

    static let shared = Panels()
    private static let tourSeenKey = "tourSeen"

    /// The tour opens by itself the first time the app launches.
    @Published var current: Kind? = UserDefaults.standard.bool(forKey: tourSeenKey) ? nil : .tour

    func show(_ kind: Kind) { current = kind }

    func close() {
        // Skipping the tour counts as seeing it: it won't open by itself again, only from the Help menu.
        if current == .tour { UserDefaults.standard.set(true, forKey: Self.tourSeenKey) }
        current = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SiteStore.shared.stopAll() }
    }
}

// MARK: - Language

/// Catalan for Catalan; Spanish for Spanish (Spain and Latin America) and the other languages
/// of Spain; English for everything else. LOCALDEMO_LANG=es|ca|en forces one (for screenshots).
enum AppLanguage: String {
    case es, ca, en

    static let current: AppLanguage = {
        if let forced = ProcessInfo.processInfo.environment["LOCALDEMO_LANG"], let lang = AppLanguage(rawValue: forced) {
            return lang
        }
        let code = Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return from(code)
    }()

    static func from(_ code: String) -> AppLanguage {
        switch code {
        case "ca": return .ca
        case "es", "gl", "eu", "ast", "an": return .es
        default: return .en
        }
    }
}

/// Reads a status message aloud with VoiceOver (it isn't focused, so it would otherwise be missed).
@MainActor func announce(_ text: String) {
    AccessibilityNotification.Announcement(text).post()
}

/// Text in the app's language.
func tr(_ es: String, ca: String, en: String) -> String {
    switch AppLanguage.current {
    case .es: return es
    case .ca: return ca
    case .en: return en
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
    @Published private(set) var errorMessage: String? {
        didSet { if let errorMessage { announce(errorMessage) } }   // read errors aloud (WCAG 4.1.3)
    }
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
            errorMessage = tr("La carpeta ya no existe. Elige otra desde el menú «…».", ca: "La carpeta ja no existeix. Tria'n una altra des del menú «…».", en: "This folder no longer exists. Choose another one from the “…” menu.")
            return
        }
        guard var port else { errorMessage = tr("El puerto debe ser un número entre 1024 y 65535.", ca: "El port ha de ser un número entre 1024 i 65535.", en: "The port must be a number between 1024 and 65535."); return }

        // If the port is taken (by another folder here, another app or another user of this Mac),
        // move to the next free one instead of failing.
        let takenHere = { (p: Int) in SiteStore.shared.sites.contains { $0 !== self && $0.isRunning && $0.port == p } }
        if takenHere(port) || !PortProbe.isFree(port) {
            guard let free = PortProbe.firstFree(after: port, excluding: takenHere) else {
                errorMessage = tr("No hay puertos libres a partir del \(port).", ca: "No hi ha ports lliures a partir del \(port).", en: "No free ports from \(port) onwards.")
                return
            }
            showNotice(tr("\(port) ocupado · usando \(free)", ca: "\(port) ocupat · fent servir \(free)", en: "\(port) busy · using \(free)"))
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
        env["LD_LANG"] = AppLanguage.current.rawValue   // pages in the same language as the app
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
            errorMessage = tr("No se pudo iniciar el servidor: \(error.localizedDescription)", ca: "No s'ha pogut iniciar el servidor: \(error.localizedDescription)", en: "Couldn't start the server: \(error.localizedDescription)")
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
        announce(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    private func friendlyError(from stderr: String) -> String {
        if stderr.contains("Address already in use") {
            return tr("El puerto \(portText) ya está en uso por otra app. Prueba con otro.", ca: "Una altra app ja fa servir el port \(portText). Prova'n un altre.", en: "Port \(portText) is already used by another app. Try another one.")
        }
        if stderr.contains("Permission denied") {
            return tr("Sin permiso para usar ese puerto o carpeta.", ca: "No hi ha permís per fer servir aquest port o carpeta.", en: "No permission to use that port or folder.")
        }
        if stderr.contains("xcode-select") || stderr.contains("developer tools") {
            return tr("Falta python3. Instala las Command Line Tools con: xcode-select --install", ca: "Falta python3. Instal·la les Command Line Tools amb: xcode-select --install", en: "python3 is missing. Install the Command Line Tools with: xcode-select --install")
        }
        let lastLine = stderr.split(separator: "\n").last.map(String.init) ?? tr("Error desconocido", ca: "Error desconegut", en: "Unknown error")
        return tr("El servidor se ha detenido: \(lastLine)", ca: "El servidor s'ha aturat: \(lastLine)", en: "The server stopped: \(lastLine)")
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
/// Settings come from the environment: LD_DIR, LD_PORT, LD_NAME, LD_PASSWORD, LD_LANG.
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

# Pages use the app's language (LD_LANG): Catalan, Spanish or English.
TEXT = {
    "es": {"protected": "Protegida con contraseña", "intro": "Escribe la contraseña para ver esta web.",
           "password": "Contraseña", "enter": "Entrar", "wrong": "Contraseña incorrecta.",
           "too_many": "Demasiados intentos. Espera un minuto.", "parent": "↑ Carpeta superior",
           "item": "elemento", "items": "elementos", "not_found": "No encontrado"},
    "ca": {"protected": "Protegida amb contrasenya", "intro": "Escriu la contrasenya per veure aquest web.",
           "password": "Contrasenya", "enter": "Entra", "wrong": "Contrasenya incorrecta.",
           "too_many": "Massa intents. Espera un minut.", "parent": "↑ Carpeta superior",
           "item": "element", "items": "elements", "not_found": "No s'ha trobat"},
    "en": {"protected": "Password protected", "intro": "Enter the password to view this site.",
           "password": "Password", "enter": "Continue", "wrong": "Wrong password.",
           "too_many": "Too many attempts. Wait a minute.", "parent": "↑ Parent folder",
           "item": "item", "items": "items", "not_found": "Not found"},
}


LANG = os.environ.get("LD_LANG", "en") if os.environ.get("LD_LANG") in TEXT else "en"

STYLE = """
:root{color-scheme:light dark;--bg:#fff;--card:#F3F1F1;--fg:#1d1d1f;--muted:#5f5f64;--field:#fff;--line:rgba(0,0,0,.12);--border:rgba(0,0,0,.45);--accent:#C63A61;--error:#C4161C}
@media (prefers-color-scheme:dark){:root{--bg:#1A1A1C;--card:#2A2A2D;--fg:#f5f5f7;--muted:#a1a1a6;--field:#1A1A1C;--line:rgba(255,255,255,.14);--border:rgba(255,255,255,.45);--error:#FF6B61}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif}
.card{background:var(--card);border-radius:20px;padding:24px}
.label{font-size:12px;font-weight:500;color:var(--muted);margin:0 0 4px}
h1{font-size:20px;font-weight:600;margin:0 0 6px;overflow-wrap:anywhere}
p{margin:0 0 20px;color:var(--muted);font-size:14px}
a{color:inherit}
"""

LOGIN_PAGE = """<!doctype html>
<html lang="{{LANG}}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{NAME}}</title><style>{{STYLE}}
body{min-height:100vh;display:grid;place-items:center;padding:16px}
form{width:100%;max-width:340px}
label{display:block;font-size:13px;font-weight:600;margin:0 0 6px}
input{width:100%;font:inherit;padding:12px 14px;border-radius:12px;border:1px solid var(--border);background:var(--field);color:var(--fg)}
input:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
button{margin-top:12px;width:100%;font:inherit;font-weight:600;padding:12px;border:0;border-radius:999px;background:var(--accent);color:#fff;cursor:pointer}
button:focus-visible{outline:2px solid var(--fg);outline-offset:2px}
.error{color:var(--error);font-size:13px;margin:10px 0 0}
</style></head><body>
<form class="card" method="post" action="/__localdemo/login">
<div class="label">{{PROTECTED}}</div>
<h1>{{NAME}}</h1>
<p>{{INTRO}}</p>
<label for="password">{{PASSWORD}}</label>
<input type="password" id="password" name="password" autocomplete="current-password" autofocus required{{INVALID}}>
<input type="hidden" name="next" value="{{NEXT}}">
{{ERROR}}
<button type="submit">{{ENTER}}</button>
</form></body></html>"""

LIST_PAGE = """<!doctype html>
<html lang="{{LANG}}"><head><meta charset="utf-8">
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

    def lang(self):
        return LANG

    def text(self, key):
        return TEXT[LANG][key]

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
            self.send_error(HTTPStatus.NOT_FOUND, self.text("not_found"))
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
            self.login_page(HTTPStatus.TOO_MANY_REQUESTS, self.text("too_many"), target)
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
        self.login_page(HTTPStatus.UNAUTHORIZED, self.text("wrong"), target)

    def login_page(self, status, error, target):
        if not SAFE_NEXT.match(target):
            target = "/"
        body = fill(LOGIN_PAGE, LANG=self.lang(),
                    PROTECTED=self.text("protected"), INTRO=self.text("intro"),
                    PASSWORD=self.text("password"), ENTER=self.text("enter"),
                    NAME=html.escape(NAME),
                    NEXT=html.escape(target, quote=True),
                    INVALID=' aria-invalid="true" aria-describedby="error"' if error else "",
                    ERROR='<p class="error" id="error" role="alert">%s</p>' % html.escape(error) if error else "")
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
            self.send_error(HTTPStatus.NOT_FOUND, self.text("not_found"))
            return None
        shown = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        items = []
        if shown != "/":
            items.append('<li><a href="../">%s</a></li>' % self.text("parent"))
        for name in names:
            label = name + ("/" if os.path.isdir(os.path.join(path, name)) else "")
            items.append('<li><a href="%s">%s</a></li>' % (urllib.parse.quote(label), html.escape(label)))
        count = "%d %s" % (len(names), self.text("item") if len(names) == 1 else self.text("items"))
        data = fill(LIST_PAGE, LANG=self.lang(), NAME=html.escape(NAME), TITLE=html.escape(shown),
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
    /// QR with a soft, rounded look: modules join into rounded shapes and the three
    /// corner markers are rounded squares. Uses error correction "Q" to stay easy to scan.
    /// No white margin is drawn: the white box around the image acts as the margin.
    @MainActor private static var cache: [String: NSImage] = [:]

    /// Cached per address, since cards redraw often (e.g. on every visit).
    @MainActor static func image(for string: String) -> NSImage? {
        if let cached = cache[string] { return cached }
        let image = draw(string, moduleSize: 20)
        cache[string] = image
        return image
    }

    static func draw(_ string: String, moduleSize: CGFloat) -> NSImage? {
        guard let matrix = modules(for: string) else { return nil }
        let n = matrix.count
        let side = CGFloat(n) * moduleSize
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            let m = moduleSize
            func dark(_ r: Int, _ c: Int) -> Bool { r >= 0 && c >= 0 && r < n && c < n && matrix[r][c] }
            func inFinder(_ r: Int, _ c: Int) -> Bool {
                (r < 7 && c < 7) || (r < 7 && c >= n - 7) || (r >= n - 7 && c < 7)
            }

            // Data modules: round each outer corner whose two neighbours on that side are empty.
            let radius = m * 0.5
            for r in 0..<n {
                for c in 0..<n where matrix[r][c] && !inFinder(r, c) {
                    let rect = CGRect(x: CGFloat(c) * m, y: CGFloat(r) * m, width: m, height: m)
                    let up = dark(r - 1, c), down = dark(r + 1, c), left = dark(r, c - 1), right = dark(r, c + 1)
                    ctx.addPath(roundedRect(rect,
                                            topLeft: !up && !left ? radius : 0,
                                            topRight: !up && !right ? radius : 0,
                                            bottomRight: !down && !right ? radius : 0,
                                            bottomLeft: !down && !left ? radius : 0))
                }
            }
            ctx.fillPath()

            // Corner markers: rounded 7×7 ring with a rounded 3×3 centre.
            for (r, c) in [(0, 0), (0, n - 7), (n - 7, 0)] {
                let outer = CGRect(x: CGFloat(c) * m, y: CGFloat(r) * m, width: 7 * m, height: 7 * m)
                let ring = CGMutablePath()
                ring.addRoundedRect(in: outer, cornerWidth: 2.2 * m, cornerHeight: 2.2 * m)
                ring.addRoundedRect(in: outer.insetBy(dx: m, dy: m), cornerWidth: 1.4 * m, cornerHeight: 1.4 * m)
                ctx.addPath(ring)
                ctx.fillPath(using: .evenOdd)
                ctx.addPath(CGPath(roundedRect: outer.insetBy(dx: 2 * m, dy: 2 * m),
                                   cornerWidth: 1.1 * m, cornerHeight: 1.1 * m, transform: nil))
                ctx.fillPath()
            }
            return true
        }
        return image
    }

    /// The QR as a grid of dark (true) / light (false) modules, without the quiet zone.
    private static func modules(for string: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Rows in memory go top to bottom; trim the generator's white margin.
        let grid = (0..<h).map { y in (0..<w).map { x in pixels[y * w + x] < 128 } }
        guard let top = grid.firstIndex(where: { $0.contains(true) }),
              let bottom = grid.lastIndex(where: { $0.contains(true) }),
              let left = (0..<w).first(where: { x in grid.contains { $0[x] } }),
              let right = (0..<w).last(where: { x in grid.contains { $0[x] } }) else { return nil }
        return (top...bottom).map { y in Array(grid[y][left...right]) }
    }

    private static func roundedRect(_ r: CGRect, topLeft: CGFloat, topRight: CGFloat,
                                    bottomRight: CGFloat, bottomLeft: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + topLeft, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - topRight, y: r.minY))
        if topRight > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: topRight) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottomRight))
        if bottomRight > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: bottomRight) }
        p.addLine(to: CGPoint(x: r.minX + bottomLeft, y: r.maxY))
        if bottomLeft > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: bottomLeft) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + topLeft))
        if topLeft > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: topLeft) }
        p.closeSubpath()
        return p
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
    /// Slightly deeper than the logo pink (D94870) so white text on it reaches WCAG AA (5:1).
    static let accent = Color(nsColor: hex(0xC63A61))
    static let onAccent = Color.white

    /// White page with warm light-grey cards, as in the reference.
    static let canvas = adaptive(light: .white, dark: hex(0x1A1A1C))
    static let card = adaptive(light: hex(0xF3F1F1), dark: hex(0x2A2A2D))

    /// Neutral fill for secondary pills and controls.
    static let pillFill = adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.10))
    /// Hover versions: a bit darker grey, and a slightly deeper accent.
    static let pillHover = adaptive(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.16))
    static let accentHover = Color(nsColor: hex(0xB5325A))
    /// Pink for text links: dark enough on light backgrounds, light enough on dark ones (≥ 4.5:1).
    static let accentText = adaptive(light: hex(0xB5325A), dark: hex(0xF08AA2))
    static let accentTextHover = adaptive(light: hex(0x9E2A4E), dark: hex(0xF7A3B7))

    /// Secondary text, a little darker than the system grey so it reaches 4.5:1 on cards and popovers.
    static let secondaryText = adaptive(light: NSColor(white: 0, alpha: 0.6), dark: NSColor(white: 1, alpha: 0.6))
    /// Error text with ≥ 4.5:1 contrast in both modes.
    static let errorText = adaptive(light: hex(0xC4161C), dark: hex(0xFF6B61))
    /// Text field border with ≥ 3:1 contrast, so the field is visible without focus.
    static let fieldBorder = adaptive(light: NSColor(white: 0, alpha: 0.45), dark: NSColor(white: 1, alpha: 0.45))
}

/// Keyboard focus indicator: a 2 pt ring in the link pink (≥ 4.9:1 on every background, light and dark),
/// drawn by our button styles instead of the system's blue ring (WCAG 2.4.7).
/// Apply it to the Button itself: inside a ButtonStyle, SwiftUI on macOS doesn't report the button's focus.
struct FocusRing<S: Shape>: ViewModifier {
    let shape: S
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .overlay {
                if focused {
                    shape.stroke(Brand.accentText, lineWidth: 2).padding(-3).allowsHitTesting(false)
                }
            }
    }
}

/// Same ring for a Menu's label, where the environment does carry the focus.
struct MenuFocusRing<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused { shape.stroke(Brand.accentText, lineWidth: 2).padding(-3).allowsHitTesting(false) }
        }
    }
}

extension View {
    func focusRing<S: Shape>(_ shape: S) -> some View { modifier(FocusRing(shape: shape)) }
}

/// Plain button (no background) with a pressed state.
struct PlainPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Tracks the pointer over a button so styles can show a hover state.
private struct HoverReader<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Rounded pill button: accent fill for the main action, neutral grey otherwise.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case prominent, neutral }
    var kind: Kind = .prominent
    /// Smaller version for popovers, same height as a text field.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 12 : 18)
                .padding(.vertical, compact ? 5 : 8)
                .foregroundStyle(kind == .prominent ? Brand.onAccent : Color.primary)
                .background(background(hovering && isEnabled), in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Capsule())
        }
    }

    private func background(_ hovering: Bool) -> Color {
        switch kind {
        case .prominent: return hovering ? Brand.accentHover : Brand.accent
        case .neutral: return hovering ? Brand.pillHover : Brand.pillFill
        }
    }
}

/// Round grey icon button (open in browser, share, carousel arrows).
struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .font(.system(size: size > 32 ? 13 : 12, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: size, height: size)
                .background(hovering ? Brand.pillHover : Brand.pillFill, in: Circle())
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Circle())
        }
    }
}

/// Quiet text button (e.g. "Limpiar"): grey, darker on hover.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(hovering ? Color.primary : Brand.secondaryText)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Text link in the CTA colour (instead of the system blue).
struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .font(.caption.weight(.medium))
                .underline(hovering)
                .foregroundStyle(hovering ? Brand.accentTextHover : Brand.accentText)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .linkCursor()
        }
    }
}

/// Pointing-hand cursor over text links (macOS shows it on links only, never on buttons).
private struct LinkCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content
                .onHover { hovering in
                    if hovering, !pushed { NSCursor.pointingHand.push(); pushed = true }
                    else if !hovering, pushed { NSCursor.pop(); pushed = false }
                }
                // The link can vanish under the pointer (e.g. a popover closing), so restore the cursor.
                .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
        }
    }
}

extension View {
    func linkCursor() -> some View { modifier(LinkCursor()) }
}

/// Text field with a neutral border that turns the CTA colour while typing (instead of the blue focus ring).
struct BrandField: View {
    /// Name read by VoiceOver (the panel title shown above the field).
    let label: String
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
            .overlay(shape.strokeBorder(focused ? Brand.accent : Brand.fieldBorder, lineWidth: focused ? 1.5 : 1))
            .tint(Brand.accent)
            .accessibilityLabel(label)
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - Main window: header + horizontal carousel of tall cards

struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    @State private var isDropTarget = false
    @State private var confirmClear = false
    @State private var scrollTarget: UUID?
    @EnvironmentObject var panels: Panels
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .padding(.top, 22)       // just below the window buttons (hidden title bar)
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
        .accessibilityHidden(panels.current != nil)   // VoiceOver stays inside the panel while it's open
        .overlay {
            if let kind = panels.current {
                ZStack {
                    // Dimmed window behind the panel; clicking it closes the panel.
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { panels.close() }
                        .accessibilityHidden(true)
                    Group {
                        switch kind {
                        case .tour: TourPanel { panels.close() }
                        case .folderHelp: HelpPanel { panels.close() }
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: panels.current)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(\.hasDirectoryPath)
            guard !folders.isEmpty else { return false }
            add(folders)
            return true
        } isTargeted: { isDropTarget = $0 }
        .confirmationDialog(tr("¿Quitar todas las carpetas?", ca: "Vols treure totes les carpetes?", en: "Remove all folders?"), isPresented: $confirmClear) {
            Button(tr("Quitar y detener", ca: "Treu i atura", en: "Remove and Stop"), role: .destructive) { store.removeAll() }
            Button(tr("Cancelar", ca: "Cancel·la", en: "Cancel"), role: .cancel) {}
        } message: {
            Text(runningCount == 1
                 ? tr("Hay 1 servidor activo y se detendrá. Las carpetas no se borran del disco.", ca: "Hi ha 1 servidor actiu i s'aturarà. Les carpetes no s'esborren del disc.", en: "1 server is running and will be stopped. The folders aren't deleted from disk.")
                 : tr("Hay \(runningCount) servidores activos y se detendrán. Las carpetas no se borran del disco.", ca: "Hi ha \(runningCount) servidors actius i s'aturaran. Les carpetes no s'esborren del disc.", en: "\(runningCount) servers are running and will be stopped. The folders aren't deleted from disk."))
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
                Text(tr("Tus páginas estáticas desde cualquier dispositivo", ca: "Les teves pàgines estàtiques des de qualsevol dispositiu", en: "Your static sites on any device"))
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)   // longer languages (e.g. Catalan) shrink slightly instead of wrapping
                    .accessibilityAddTraits(.isHeader)
                Text(tr("Arrastra aquí tus proyectos y accede a ellos desde cualquier dispositivo conectado al mismo wifi.", ca: "Arrossega aquí els teus projectes i accedeix-hi des de qualsevol dispositiu connectat a la mateixa wifi.", en: "Drop your projects here and open them on any device connected to the same Wi‑Fi."))
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer()
            if needsArrows {
                HStack(spacing: 8) {
                    arrowButton("chevron.left", label: tr("Anterior", ca: "Anterior", en: "Previous")) { step(-1) }
                    arrowButton("chevron.right", label: tr("Siguiente", ca: "Següent", en: "Next")) { step(1) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 32)
    }

    private func arrowButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(CircleButtonStyle(size: 32))
        .focusRing(Circle())
        .help(label)
        .accessibilityLabel(label)
    }

    private var carousel: some View {
        // "Add folder" stays pinned on the left; only the folder cards scroll.
        HStack(spacing: 0) {
            AddCard(onChoose: chooseFolders, onHelp: { panels.show(.folderHelp) })
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
                Button(tr("Limpiar", ca: "Neteja", en: "Clear")) {
                    if runningCount > 0 { confirmClear = true } else { store.removeAll() }
                }
                .buttonStyle(QuietButtonStyle())
                .focusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help(tr("Quitar todas las carpetas", ca: "Treu totes les carpetes", en: "Remove all folders"))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Brand.secondaryText)
        .padding(.horizontal, 32)
    }

    private var summary: String {
        let total = store.sites.count
        if total == 0 { return tr("Sin carpetas todavía", ca: "Encara no hi ha carpetes", en: "No folders yet") }
        let folders = total == 1 ? tr("1 carpeta", ca: "1 carpeta", en: "1 folder") : tr("\(total) carpetas", ca: "\(total) carpetes", en: "\(total) folders")
        return runningCount == 0 ? folders : "\(folders) · \(runningCount) " + (runningCount == 1 ? tr("activa", ca: "activa", en: "running") : tr("activas", ca: "actives", en: "running"))
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
        panel.prompt = tr("Añadir", ca: "Afegeix", en: "Add")
        panel.message = tr("Elige una o varias carpetas con tu web (por ejemplo, las que tienen un index.html)", ca: "Tria una o més carpetes amb el teu web (per exemple, les que tenen un index.html)", en: "Choose one or more folders with your site (for example, ones with an index.html)")
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

// MARK: - Card shell

/// Tall rounded card with a flat warm-grey background; on hover it lifts 2 pt with a faint shadow.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        content()
            .frame(width: ContentView.cardSize.width, height: ContentView.cardSize.height)
            .background(Brand.card, in: shape)
            .clipShape(shape)
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .shadow(color: .black.opacity(hovering ? 0.05 : 0), radius: 12, y: 6)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.25), value: hovering)
            .focusSection()   // Tab goes through one card completely before moving to the next
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
    @State private var hoveringMenu = false
    @State private var hoveringTrash = false
    @State private var nameDraft = ""
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            Button(tr("Cambiar nombre…", ca: "Canvia el nom…", en: "Rename…"), action: renameSite)
            Button(tr("Mostrar en Finder", ca: "Mostra al Finder", en: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) }
            Button(tr("Cambiar carpeta…", ca: "Canvia la carpeta…", en: "Change Folder…"), action: changeFolder).disabled(site.isRunning)
            Divider()
            Button(tr("Quitar de la lista", ca: "Treu de la llista", en: "Remove from List")) { SiteStore.shared.remove(site) }.disabled(site.isRunning)
        }
    }

    private func topRow() -> some View {
        HStack(spacing: 8) {
            Image(systemName: site.isRunning ? "dot.radiowaves.left.and.right" : "folder")
                .font(.system(size: 15, weight: .regular))
                // The waves light up briefly when the server starts and on each visit. Short bursts (not an
                // endless loop) keep it within WCAG 2.2.2, and it's off when Reduce Motion is on.
                .symbolEffect(.variableColor.iterative.reversing, options: .repeat(2), value: activityPulse)
                .symbolEffectsRemoved(reduceMotion)
                .accessibilityHidden(true)   // the state is already said in text ("Activa · 3 visitas")
            if site.hasPassword {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.secondaryText)
                    .help(tr("Protegida con contraseña", ca: "Protegida amb contrasenya", en: "Password protected"))
                    .accessibilityLabel(tr("Protegida con contraseña", ca: "Protegida amb contrasenya", en: "Password protected"))
            }
            Spacer()
            if site.isRunning, let url = site.shareURL, let link = URL(string: url) {
                // Opens the site in the default browser.
                Button { open(url) } label: {
                    Image(systemName: "display")
                }
                .buttonStyle(CircleButtonStyle(size: 30))
                .focusRing(Circle())
                .help(tr("Abrir en el navegador", ca: "Obre al navegador", en: "Open in browser"))
                .accessibilityLabel(tr("Abrir en el navegador", ca: "Obre al navegador", en: "Open in browser"))

                // Native macOS share menu (AirDrop, Mensajes, Mail, Notas…) with the address.
                ShareLink(item: link) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(CircleButtonStyle(size: 30))
                .focusRing(Circle())
                .help(tr("Compartir dirección", ca: "Comparteix l'adreça", en: "Share address"))
                .accessibilityLabel(tr("Compartir dirección", ca: "Comparteix l'adreça", en: "Share address"))
            }
            if !site.isRunning {
                // Removes the folder from the app (it stays on disk). Same look as the "…" button next to it.
                Button { SiteStore.shared.remove(site) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(hoveringTrash ? Brand.pillFill : .clear, in: Circle())
                        .foregroundStyle(hoveringTrash ? Color.primary : Brand.secondaryText)
                        .contentShape(Circle())
                        .onHover { hoveringTrash = $0 }
                        .animation(.easeOut(duration: 0.12), value: hoveringTrash)
                }
                .buttonStyle(PlainPressStyle())
                .focusRing(Circle())
                .help(tr("Quitar de la lista", ca: "Treu de la llista", en: "Remove from List"))
                .accessibilityLabel(tr("Quitar \(site.name) de la lista", ca: "Treu \(site.name) de la llista", en: "Remove \(site.name) from list"))

                Menu {
                    Button(tr("Cambiar nombre…", ca: "Canvia el nom…", en: "Rename…"), action: renameSite)
                    Button(tr("Cambiar puerto…", ca: "Canvia el port…", en: "Change Port…")) { portDraft = site.portText; editingPort = true }
                    Button(site.hasPassword ? tr("Cambiar contraseña…", ca: "Canvia la contrasenya…", en: "Change Password…") : tr("Poner contraseña…", ca: "Posa una contrasenya…", en: "Set Password…")) {
                        passwordDraft = site.password; editingPassword = true
                    }
                    Button(tr("Mostrar en Finder", ca: "Mostra al Finder", en: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) }
                    Button(tr("Cambiar carpeta…", ca: "Canvia la carpeta…", en: "Change Folder…"), action: changeFolder)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(hoveringMenu ? Brand.pillFill : .clear, in: Circle())
                        .foregroundStyle(hoveringMenu ? Color.primary : Brand.secondaryText)
                        .contentShape(Circle())
                        .modifier(MenuFocusRing(shape: Circle()))
                        .onHover { hoveringMenu = $0 }
                        .animation(.easeOut(duration: 0.12), value: hoveringMenu)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Brand.secondaryText)
                .help(tr("Opciones", ca: "Opcions", en: "Options"))
                .accessibilityLabel(tr("Opciones de \(site.name)", ca: "Opcions de \(site.name)", en: "Options for \(site.name)"))
                .popover(isPresented: $editingPort, arrowEdge: .bottom) { portEditor }
            }
        }
        .foregroundStyle(.primary)
        .frame(height: 30)
        .popover(isPresented: $editingPassword, arrowEdge: .bottom) { passwordEditor }
    }

    /// Changes when the server starts and on every visit, to play the short wave animation.
    private var activityPulse: String { "\(site.isRunning)-\(site.requestCount)" }

    private func qrTile(_ url: String) -> some View {
        Button { showQR = true } label: {
            if let qr = QRCode.image(for: url) {
                Image(nsImage: qr)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .padding(6)
                    .background {
                        // White box with a soft shadow under it (the shadow is on the box only).
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                    }
            }
        }
        .buttonStyle(PlainPressStyle())
        .focusRing(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(tr("Ampliar código QR", ca: "Amplia el codi QR", en: "Enlarge QR code"))
        .accessibilityLabel(tr("Ampliar código QR", ca: "Amplia el codi QR", en: "Enlarge QR code"))
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
                    Text(site.notice ?? (site.requestCount == 1 ? tr("Activa · 1 visita", ca: "Activa · 1 visita", en: "Live · 1 visit") : tr("Activa · \(site.requestCount) visitas", ca: "Activa · \(site.requestCount) visites", en: "Live · \(site.requestCount) visits")))
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.secondaryText)
            } else {
                Button { portDraft = site.portText; editingPort = true } label: {
                    Text(tr("Puerto \(site.portText)", ca: "Port \(site.portText)", en: "Port \(site.portText)"))
                        .monospacedDigit()
                }
                .buttonStyle(PlainPressStyle())
                .focusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.secondaryText)
                .help(tr("Cambiar puerto", ca: "Canvia el port", en: "Change port"))
            }

            Text(site.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .help("\(site.folder.path)\n" + tr("Doble clic para cambiar el nombre", ca: "Fes doble clic per canviar el nom", en: "Double-click to rename"))
                .onTapGesture(count: 2, perform: renameSite)
                .popover(isPresented: $editingName, arrowEdge: .bottom) { nameEditor }

            description()

            HStack(spacing: 8) {
                if site.isRunning {
                    Button(tr("Detener", ca: "Atura", en: "Stop")) { site.stop() }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                        .focusRing(Capsule())
                } else {
                    Button(tr("Iniciar", ca: "Inicia", en: "Start")) { site.start() }
                        .buttonStyle(PillButtonStyle(kind: .prominent))
                        .focusRing(Capsule())
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
                .foregroundStyle(Brand.errorText)
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
                        Label(tr("URL en el portapapeles", ca: "URL al porta-retalls", en: "URL copied to clipboard"), systemImage: "checkmark")
                    } else {
                        Text(shown).monospacedDigit()
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Brand.secondaryText)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: copied)
            }
            .buttonStyle(PlainPressStyle())
            .focusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
            .help(tr("Copiar dirección", ca: "Copia l'adreça", en: "Copy address"))
            .accessibilityLabel(tr("Copiar dirección \(shown)", ca: "Copia l'adreça \(shown)", en: "Copy address \(shown)"))
        } else {
            // With a custom name, include the folder itself so it's still clear what is served.
            let shownFolder = site.customName.isEmpty ? site.folder.deletingLastPathComponent() : site.folder
            Text((shownFolder.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12))
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(2)
                .truncationMode(.head)
        }
    }

    private var portEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Puerto", ca: "Port", en: "Port")).font(.headline)
            HStack(spacing: 8) {
                BrandField(label: tr("Puerto", ca: "Port", en: "Port"), placeholder: "8000", text: $portDraft, onSubmit: applyPort)
                    .frame(width: 80)
                Button(tr("Aceptar", ca: "D'acord", en: "OK"), action: applyPort)
                    .buttonStyle(PillButtonStyle(kind: .prominent, compact: true))
                    .focusRing(Capsule())
                    .keyboardShortcut(.defaultAction)
            }
            Text(tr("Libres: ", ca: "Lliures: ", en: "Free: ") + suggestedPorts.prefix(4).map(String.init).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
        }
        .padding(14)
        .focusEffectDisabled()   // popovers: same pink focus ring as the window
    }

    private var suggestedPorts: [Int] {
        let used = Set(SiteStore.shared.sites.filter { $0 !== site }.compactMap(\.port))
        return Array((8000...8099).lazy.filter { !used.contains($0) && PortProbe.isFree($0) }.prefix(4))
    }

    private var passwordEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Contraseña", ca: "Contrasenya", en: "Password")).font(.headline)
            Text(tr("Quien abra la web tendrá que escribirla.\nNo uses una contraseña personal.", ca: "Qui obri el web l'haurà d'escriure.\nNo facis servir una contrasenya personal.", en: "Anyone opening the site will have to enter it.\nDon't use a personal password."))
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                BrandField(label: tr("Contraseña", ca: "Contrasenya", en: "Password"), placeholder: tr("Sin contraseña", ca: "Sense contrasenya", en: "No password"), text: $passwordDraft, onSubmit: applyPassword)
                    .frame(width: 150)
                Button(tr("Aceptar", ca: "D'acord", en: "OK"), action: applyPassword)
                    .buttonStyle(PillButtonStyle(kind: .prominent, compact: true))
                    .focusRing(Capsule())
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 12) {
                Button(tr("Generar", ca: "Genera", en: "Generate")) { passwordDraft = Self.randomPassword() }
                    .focusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
                if site.hasPassword {
                    Button(tr("Quitar contraseña", ca: "Treu la contrasenya", en: "Remove password")) { passwordDraft = ""; applyPassword() }
                        .focusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .buttonStyle(LinkStyle())
        }
        .padding(14)
        .focusEffectDisabled()   // popovers: same pink focus ring as the window
        .frame(width: 260, alignment: .leading)
    }

    private func renameSite() {
        nameDraft = site.customName
        editingName = true
    }

    var nameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Nombre", ca: "Nom", en: "Name")).font(.headline)
            HStack(spacing: 8) {
                BrandField(label: tr("Nombre", ca: "Nom", en: "Name"), placeholder: site.folder.lastPathComponent, text: $nameDraft, onSubmit: applyName)
                    .frame(width: 180)
                Button(tr("Aceptar", ca: "D'acord", en: "OK"), action: applyName)
                    .buttonStyle(PillButtonStyle(kind: .prominent, compact: true))
                    .focusRing(Capsule())
                    .keyboardShortcut(.defaultAction)
            }
            if !site.customName.isEmpty {
                Button(tr("Usar el nombre de la carpeta", ca: "Fes servir el nom de la carpeta", en: "Use folder name")) { nameDraft = ""; applyName() }
                    .buttonStyle(LinkStyle())
                    .focusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(14)
        .focusEffectDisabled()   // popovers: same pink focus ring as the window
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
        panel.prompt = tr("Elegir", ca: "Tria", en: "Choose")
        panel.directoryURL = site.folder
        if panel.runModal() == .OK, let url = panel.url { site.folder = url }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        announce(tr("URL en el portapapeles", ca: "URL al porta-retalls", en: "URL copied to clipboard"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Last card: add folders

struct AddCard: View {
    var onChoose: () -> Void
    var onHelp: () -> Void
    @State private var hoveringHelp = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .accessibilityHidden(true)
                    Spacer()
                    // Opens the panel that explains which folder to choose. Same look as the card's "…" button.
                    Button(action: onHelp) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 28, height: 28)
                            .background(hoveringHelp ? Brand.pillFill : .clear, in: Circle())
                            .foregroundStyle(hoveringHelp ? Color.primary : Brand.secondaryText)
                            .contentShape(Circle())
                            .onHover { hoveringHelp = $0 }
                            .animation(.easeOut(duration: 0.12), value: hoveringHelp)
                    }
                    .buttonStyle(PlainPressStyle())
                    .focusRing(Circle())
                    .help(tr("¿Qué carpeta elijo?", ca: "Quina carpeta trio?", en: "Which folder should I choose?"))
                    .accessibilityLabel(tr("Ayuda: ¿qué carpeta elijo?", ca: "Ajuda: quina carpeta trio?", en: "Help: which folder should I choose?"))
                }
                .frame(height: 30)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Añadir carpeta", ca: "Afegeix una carpeta", en: "Add folder"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(tr("Arrástrala a la ventana o elígela desde Finder.", ca: "Arrossega-la a la finestra o tria-la des del Finder.", en: "Drop it on the window or choose it in Finder."))
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(tr("Elegir", ca: "Tria", en: "Choose"), action: onChoose)
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                        .focusRing(Capsule())
                        .padding(.top, 8)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onTapGesture(perform: onChoose)
    }
}

// MARK: - Tour: the main features, shown on first launch and from Help > Local Demo Tour

struct TourPanel: View {
    var onClose: () -> Void
    @State private var index = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Step {
        /// SF Symbol, or nil for the app icon.
        let symbol: String?
        let title: String
        let text: String
    }

    private let steps: [Step] = [
        Step(symbol: nil,
             title: tr("Te damos la bienvenida a Local Demo", ca: "Et donem la benvinguda a Local Demo", en: "Welcome to Local Demo"),
             text: tr("Enseña tus webs en el móvil, la tablet u otro ordenador conectado a tu wifi, sin usar el Terminal.",
                      ca: "Ensenya els teus webs al mòbil, la tauleta o un altre ordinador connectat a la teva wifi, sense fer servir el Terminal.",
                      en: "Show your sites on a phone, tablet or another computer on your Wi‑Fi, no Terminal needed.")),
        Step(symbol: "folder.badge.plus",
             title: tr("Añade tus carpetas", ca: "Afegeix les teves carpetes", en: "Add your folders"),
             text: tr("Arrastra a la ventana una o varias carpetas con tu web, o elígelas desde la tarjeta «Añadir carpeta». Cada una tiene su propio puerto.",
                      ca: "Arrossega a la finestra una o més carpetes amb el teu web, o tria-les des de la targeta «Afegeix una carpeta». Cada una té el seu propi port.",
                      en: "Drop one or more folders with your site on the window, or choose them from the “Add folder” card. Each one gets its own port.")),
        Step(symbol: "qrcode",
             title: tr("Inicia y escanea", ca: "Inicia i escaneja", en: "Start and scan"),
             text: tr("Pulsa Iniciar y escanea el código QR con el móvil. También puedes copiar la dirección, abrirla en el navegador o compartirla.",
                      ca: "Prem Inicia i escaneja el codi QR amb el mòbil. També pots copiar l'adreça, obrir-la al navegador o compartir-la.",
                      en: "Click Start and scan the QR code with your phone. You can also copy the address, open it in the browser or share it.")),
        Step(symbol: "lock",
             title: tr("Ponle nombre y contraseña", ca: "Posa-hi nom i contrasenya", en: "Name it and lock it"),
             text: tr("En el menú «…» de cada carpeta puedes cambiarle el nombre o el puerto, y protegerla con una contraseña que tus visitas tendrán que escribir.",
                      ca: "Al menú «…» de cada carpeta pots canviar-ne el nom o el port, i protegir-la amb una contrasenya que les teves visites hauran d'escriure.",
                      en: "From each folder’s “…” menu you can rename it, change its port and protect it with a password your visitors have to enter.")),
        Step(symbol: "wifi",
             title: tr("Antes de empezar", ca: "Abans de començar", en: "Before you start"),
             text: tr("Los dispositivos tienen que estar en la misma wifi. Detén los servidores cuando acabes: mientras están activos, la carpeta está abierta en la red.",
                      ca: "Els dispositius han d'estar a la mateixa wifi. Atura els servidors quan acabis: mentre estan actius, la carpeta és oberta a la xarxa.",
                      en: "Devices must be on the same Wi‑Fi. Stop the servers when you’re done: while they’re running, the folder is open on the network.")),
    ]

    private var isLast: Bool { index == steps.count - 1 }
    private var stepLabel: String {
        tr("Paso \(index + 1) de \(steps.count)", ca: "Pas \(index + 1) de \(steps.count)", en: "Step \(index + 1) of \(steps.count)")
    }

    var body: some View {
        let step = steps[index]
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(tr("Saltar", ca: "Omet", en: "Skip"), action: onClose)
                    .buttonStyle(QuietButtonStyle())
                    .font(.system(size: 13))
                    .focusRing(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .keyboardShortcut(.cancelAction)   // Esc skips the tour
                    .opacity(isLast ? 0 : 1)
                    .disabled(isLast)
                    .accessibilityHidden(isLast)
            }

            VStack(spacing: 14) {
                illustration(step)
                Text(step.title)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(step.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if isLast {
                    Text(tr("Puedes volver a verlo cuando quieras en Ayuda > Recorrido por Local Demo.",
                            ca: "Pots tornar-lo a veure quan vulguis a Ajuda > Recorregut per Local Demo.",
                            en: "You can see it again any time from Help > Local Demo Tour."))
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 244, alignment: .top)
            .id(index)
            .transition(.opacity)
            .accessibilityElement(children: .combine)

            HStack {
                dots
                Spacer()
                if index > 0 {
                    Button(tr("Atrás", ca: "Enrere", en: "Back")) { go(-1) }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                        .focusRing(Capsule())
                }
                Button(isLast ? tr("Empezar", ca: "Comença", en: "Get Started") : tr("Siguiente", ca: "Següent", en: "Next")) {
                    if isLast { onClose() } else { go(1) }
                }
                .buttonStyle(PillButtonStyle())
                .focusRing(Capsule())
                .keyboardShortcut(.defaultAction)   // Return moves forward
                .focused($focused)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 440)
        .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    @ViewBuilder
    private func illustration(_ step: Step) -> some View {
        Group {
            if let symbol = step.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Brand.accentText)
                    .frame(width: 84, height: 84)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
        }
        .frame(height: 96)
        .accessibilityHidden(true)
    }

    /// Page dots: the current one is a longer pink pill. Clicking one jumps to that step.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Brand.accent : Brand.pillHover)
                    .frame(width: i == index ? 18 : 7, height: 7)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { go(i - index) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(stepLabel)
    }

    private func go(_ delta: Int) {
        let next = max(0, min(steps.count - 1, index + delta))
        guard next != index else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { index = next }
        announce("\(stepLabel): \(steps[next].title)")
        focused = true
    }
}

// MARK: - Help panel: which folder to choose, for people who don't build websites

struct HelpPanel: View {
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("¿Qué carpeta elijo?", ca: "Quina carpeta trio?", en: "Which folder should I choose?"))
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(CircleButtonStyle(size: 28))
                    .focusRing(Circle())
                    .keyboardShortcut(.cancelAction)   // Esc closes the panel
                    .help(tr("Cerrar", ca: "Tanca", en: "Close"))
                    .accessibilityLabel(tr("Cerrar", ca: "Tanca", en: "Close"))
            }

            item("doc.richtext",
                 title: tr("La carpeta de tu web", ca: "La carpeta del teu web", en: "Your website's folder"),
                 text: tr("Elige la carpeta que tiene dentro un archivo llamado index.html. Es la página que se abre en el móvil al escanear el código QR.",
                          ca: "Tria la carpeta que té a dins un fitxer anomenat index.html. És la pàgina que s'obre al mòbil quan escaneges el codi QR.",
                          en: "Choose the folder that has a file called index.html inside. It's the page that opens on the phone when you scan the QR code."))
            item("hand.tap",
                 title: tr("Cómo comprobarlo", ca: "Com comprovar-ho", en: "How to check"),
                 text: tr("Haz doble clic en index.html. Si la web se ve bien en tu navegador, también se verá bien en el móvil.",
                          ca: "Fes doble clic a index.html. Si el web es veu bé al navegador, també es veurà bé al mòbil.",
                          en: "Double-click index.html. If the site looks right in your browser, it will look right on the phone too."))
            item("person.2",
                 title: tr("Si te la ha preparado otra persona", ca: "Si te l'ha preparat una altra persona", en: "If someone else made it for you"),
                 text: tr("Pídele «la versión final, la que se abre con doble clic en el index.html». Suele estar en una carpeta llamada dist o build.",
                          ca: "Demana-li «la versió final, la que s'obre amb doble clic a l'index.html». Sol ser en una carpeta anomenada dist o build.",
                          en: "Ask them for “the final version, the one that opens when you double-click index.html”. It's usually in a folder called dist or build."))
            item("exclamationmark.circle",
                 title: tr("Lo que no funcionará", ca: "El que no funcionarà", en: "What won't work"),
                 text: tr("Formularios que envían datos, inicios de sesión, compras o cualquier cosa que guarde información. Local Demo solo enseña la web.",
                          ca: "Formularis que envien dades, inicis de sessió, compres o qualsevol cosa que desi informació. Local Demo només ensenya el web.",
                          en: "Forms that send data, sign-ins, purchases or anything that saves information. Local Demo only shows the site."))

            HStack {
                Spacer()
                Button(tr("Entendido", ca: "Entesos", en: "Got it"), action: onClose)
                    .buttonStyle(PillButtonStyle())
                    .focusRing(Capsule())
                    .keyboardShortcut(.defaultAction)   // Return closes it too
                    .focused($focused)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func item(_ symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Brand.accentText)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
                    .resizable()
                    .frame(width: 176, height: 176)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel(tr("Código QR de \(url)", ca: "Codi QR de \(url)", en: "QR code for \(url)"))
            }
            VStack(spacing: 3) {
                Text(url.replacingOccurrences(of: "http://", with: ""))
                    .font(.system(size: 15, weight: .bold))
                    .textSelection(.enabled)
                Text(visits == 1 ? tr("Escanéalo con el móvil · 1 visita", ca: "Escaneja'l amb el mòbil · 1 visita", en: "Scan it with your phone · 1 visit") : tr("Escanéalo con el móvil · \(visits) visitas", ca: "Escaneja'l amb el mòbil · \(visits) visites", en: "Scan it with your phone · \(visits) visits"))
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .monospacedDigit()
                if !password.isEmpty {
                    Label(tr("Contraseña: \(password)", ca: "Contrasenya: \(password)", en: "Password: \(password)"), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
        }
        .padding(20)
    }
}
