// Board app: native window for the to-do board (WebKit, no background server) and the daily notification.
// The page talks to TodoStore through a WebKit message bridge; data lives in todos.json (shared with server.py).
// Launched with --notify by daily-reminder.sh. Build: build-notifier.sh
// Self-updates from the git remote (see Updater); log in update.log.
import AppKit
import UserNotifications
import WebKit

// Board folder: TABLERO_DIR, else the folder build-notifier.sh stamped into Info.plist (TableroDir), else ~/tablero.
let todoDir = ProcessInfo.processInfo.environment["TABLERO_DIR"].map { URL(fileURLWithPath: $0) }
    ?? (Bundle.main.object(forInfoDictionaryKey: "TableroDir") as? String).map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tablero")
let statuses: Set<String> = ["todo", "doing", "qa", "done"]
let defaultAppName = "Tablero"
let bundleID = "io.github.darwin-elegiga.tablero" // keep stable: notification permission and window frame hang on it
let configFile = todoDir.appendingPathComponent("config.json")

/// Local settings (config.json, not in git), e.g. {"name": "Mi tablero"}.
func readConfig() -> [String: Any] {
    guard let data = try? Data(contentsOf: configFile) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// The board's user-chosen name, or the default.
func appName() -> String {
    let name = (readConfig()["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? defaultAppName : name
}
let trashDays = 30.0 // deleted notes stay in the trash at least this long

final class TodoStore {
    private let file = todoDir.appendingPathComponent("todos.json")
    private let labelsFile = todoDir.appendingPathComponent("labels.json")
    private let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    func load() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              var todos = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let cutoff = Date().addingTimeInterval(-trashDays * 86400)
        todos.removeAll { todo in
            guard let deleted = todo["deleted"] as? String, let date = timestamp.date(from: deleted) else { return false }
            return date < cutoff
        }
        for i in todos.indices {
            if todos[i]["status"] == nil { todos[i]["status"] = (todos[i]["done"] as? Bool ?? false) ? "done" : "todo" }
            if todos[i]["order"] == nil { todos[i]["order"] = Double(i) }
        }
        return todos
    }

    func save(_ todos: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: todos, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        try? (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    func pendingCount() -> Int {
        load().filter { $0["status"] as? String != "done" && $0["deleted"] == nil }.count
    }

    /// Mirrors server.py's /api/labels: project name -> note color.
    func handleLabels(method: String, body: [String: Any]) -> String? {
        if method == "PUT" {
            guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            try? (data + Data("\n".utf8)).write(to: labelsFile, options: .atomic)
            return json(body)
        }
        guard let data = try? Data(contentsOf: labelsFile),
              let labels = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }
        return json(labels)
    }

    /// Mirrors server.py's /api/config. An empty name resets to the default.
    func handleConfig(method: String, body: [String: Any]) -> String? {
        var config = readConfig()
        if method == "PUT" {
            let name = String((body["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            if name.isEmpty { config.removeValue(forKey: "name") } else { config["name"] = name }
            guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            try? (data + Data("\n".utf8)).write(to: configFile, options: .atomic)
        }
        return json(config)
    }

    /// Mirrors server.py's REST API. Returns a JSON string, or nil for "no content".
    func handle(method: String, id: String, body: [String: Any]) -> String? {
        var todos = load()
        switch method {
        case "GET":
            return json(todos)
        case "POST":
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return json(["error": "text is required"]) }
            let project = (body["project"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let status = statuses.contains(body["status"] as? String ?? "") ? body["status"] as! String : "todo"
            let todo: [String: Any] = [
                "id": String(UUID().uuidString.lowercased().prefix(8)),
                "text": text,
                "project": project.isEmpty ? "General" : project,
                "status": status,
                "done": status == "done",
                "order": body["order"] as? Double ?? Date().timeIntervalSince1970,
                "created": timestamp.string(from: Date()),
            ]
            todos.append(todo)
            save(todos)
            return json(todo)
        case "PATCH":
            guard let i = todos.firstIndex(where: { $0["id"] as? String == id }) else { return nil }
            // Reordering alone is not a modification; content or column changes are.
            if ["text", "project", "status"].contains(where: { key in
                guard let value = body[key] as? String else { return false }
                return value != todos[i][key] as? String
            }) {
                todos[i]["updated"] = timestamp.string(from: Date())
            }
            for key in ["text", "project", "status", "order"] where body[key] != nil {
                todos[i][key] = body[key]
            }
            if body["deleted"] is NSNull { todos[i].removeValue(forKey: "deleted") } // restore from trash
            if let done = body["done"] as? Bool, body["status"] == nil { todos[i]["status"] = done ? "done" : "todo" }
            todos[i]["done"] = todos[i]["status"] as? String == "done"
            save(todos)
            return json(todos[i])
        case "DELETE":
            // First delete moves the note to the trash; deleting it from the trash removes it for good.
            guard let i = todos.firstIndex(where: { $0["id"] as? String == id }) else { return nil }
            if todos[i]["deleted"] != nil {
                todos.remove(at: i)
            } else {
                todos[i]["deleted"] = timestamp.string(from: Date())
            }
            save(todos)
            return nil
        default:
            return nil
        }
    }

    private func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Runs a command in todoDir and returns its exit status and combined output.
@discardableResult
func run(_ executable: String, _ args: [String], env extra: [String: String] = [:]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = todoDir
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" // apps launched from Finder get a minimal PATH
    extra.forEach { env[$0.key] = $0.value }
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Self-update from the git remote: fast-forward todoDir to origin/main, then reload the page
/// or rebuild and relaunch the app when native files changed. Never touches local commits or edits,
/// and only applies commits signed by a key in .git/info/allowed_signers (local, never synced).
final class Updater {
    static let interval: TimeInterval = 6 * 3600
    private static let nativeFiles: Set<String> = ["notifier.swift", "build-notifier.sh", "icon.png"]
    private let queue = DispatchQueue(label: "tablero.updater")
    private let logFile = todoDir.appendingPathComponent("update.log")

    var onPageUpdated: (() -> Void)?
    var onAppRebuilt: (() -> Void)?
    /// (message, worth a notification). Called on the main thread.
    var onResult: ((String, Bool) -> Void)?

    func check() { queue.async { self.perform() } }

    private func git(_ args: String...) -> (status: Int32, output: String) {
        run("/usr/bin/git", args, env: [
            "GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o ConnectTimeout=15",
            "GIT_TERMINAL_PROMPT": "0",
        ])
    }

    private func perform() {
        func finish(_ message: String, updated: Bool = false, detail: String = "") {
            log(detail.isEmpty ? message : "\(message)\n\(detail)")
            DispatchQueue.main.async { self.onResult?(message, updated) }
        }
        let fetch = git("fetch", "--quiet", "origin", "main")
        guard fetch.status == 0 else { return finish("No se pudo consultar GitHub (sin red o sin acceso SSH).", detail: fetch.output) }
        let head = git("rev-parse", "HEAD").output
        let remote = git("rev-parse", "origin/main").output
        guard head != remote else { return finish("\(appName()) ya está en la última versión (\(head.prefix(7))).") }
        guard git("merge-base", "--is-ancestor", "HEAD", "origin/main").status == 0 else {
            return finish("Hay commits locales que no están en GitHub; no se actualiza.")
        }
        guard git("status", "--porcelain", "--untracked-files=no").output.isEmpty else {
            return finish("Hay cambios locales sin commit; no se actualiza.")
        }
        // A compromised GitHub account must not be able to run code here: every incoming commit
        // needs a good signature ("G") from a key the local allowed_signers file trusts.
        let unsigned = git("log", "--format=%h %G? %an: %s", "HEAD..origin/main").output
            .split(separator: "\n").filter { $0.split(separator: " ").dropFirst().first != "G" }
        guard unsigned.isEmpty else {
            return finish("Hay commits en GitHub sin tu firma: no se actualiza por seguridad. Revisa update.log.",
                          updated: true, detail: unsigned.joined(separator: "\n"))
        }
        let changed = Set(git("diff", "--name-only", head, remote).output.split(separator: "\n").map(String.init))
        let merge = git("merge", "--ff-only", "--quiet", "origin/main")
        guard merge.status == 0 else { return finish("Falló la actualización (git merge).", detail: merge.output) }
        log("Updated \(head.prefix(7)) -> \(remote.prefix(7)): \(changed.sorted().joined(separator: ", "))")

        if !changed.isDisjoint(with: Self.nativeFiles) {
            guard buildApp() else {
                return finish("Código actualizado, pero la recompilación falló: sigue la app anterior. Detalles en update.log.")
            }
            finish("\(appName()) actualizado a \(remote.prefix(7)). Se reinicia.", updated: true)
            DispatchQueue.main.async { self.onAppRebuilt?() }
        } else {
            finish("\(appName()) actualizado a \(remote.prefix(7)).", updated: true)
            if changed.contains("index.html") { DispatchQueue.main.async { self.onPageUpdated?() } }
        }
    }

    /// Rebuild the bundle (e.g. after a rename) and relaunch it.
    func rebuild() {
        queue.async {
            if self.buildApp() {
                DispatchQueue.main.async { self.onAppRebuilt?() }
            } else {
                DispatchQueue.main.async { self.onResult?("La recompilación falló. Detalles en update.log.", false) }
            }
        }
    }

    private func buildApp() -> Bool {
        let build = run("/bin/zsh", [todoDir.appendingPathComponent("build-notifier.sh").path])
        if build.status != 0 { log("Build failed:\n\(build.output)") }
        return build.status == 0
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = Data("[\(stamp)] \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: logFile)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, WKScriptMessageHandlerWithReply, WKUIDelegate {
    let store = TodoStore()
    let updater = Updater()
    var window: NSWindow?
    var webView: WKWebView?
    private var manualCheck = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        startUpdater()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let notify = CommandLine.arguments.contains("--notify")
        let pending = store.pendingCount()
        // Daily reminder with nothing pending: stay silent, no window.
        if notify && pending == 0 { return NSApp.terminate(nil) }
        showWindow()
        guard notify else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = "Revisión diaria"
            content.body = pending == 1 ? "Tienes 1 tarea sin terminar" : "Tienes \(pending) tareas sin terminar"
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))
            center.add(UNNotificationRequest(identifier: "daily-review", content: content, trigger: nil))
        }
    }

    private func startUpdater() {
        updater.onPageUpdated = { [weak self] in self?.webView?.reload() }
        updater.onAppRebuilt = { [weak self] in self?.relaunch() }
        updater.onResult = { [weak self] message, updated in
            guard let self else { return }
            if self.manualCheck {
                self.manualCheck = false
                let alert = NSAlert()
                alert.messageText = message
                alert.runModal()
            } else if updated {
                self.postNotification(id: "tablero-updated", title: appName(), body: message)
            }
        }
        // First check shortly after launch, then periodically while the app stays open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.updater.check() }
        Timer.scheduledTimer(withTimeInterval: Updater.interval, repeats: true) { [weak self] _ in self?.updater.check() }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        manualCheck = true
        updater.check()
    }

    /// The rebuilt bundle replaced ours on disk (maybe under a new name): start it by bundle id once we quit.
    private func relaunch() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "sleep 1; /usr/bin/open -b \"$0\"", Bundle.main.bundleIdentifier ?? bundleID]
        try? relauncher.run()
        NSApp.terminate(nil)
    }

    private func postNotification(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Window and menus pick the new name at once; the Dock/menu-bar name needs a rebuild.
    private func nameChanged() {
        window?.title = appName()
        buildMenu()
        let alert = NSAlert()
        alert.messageText = "Nombre cambiado a «\(appName())»"
        alert.informativeText = "Para verlo también en el Dock y en la barra de menús, la app se recompila y se reinicia."
        alert.addButton(withTitle: "Reiniciar ahora")
        alert.addButton(withTitle: "Más tarde")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manualCheck = true // a failed rebuild shows an alert
        updater.rebuild()
    }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "todos")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.uiDelegate = self // without it, confirm()/prompt() silently return false/null
        webView.loadFileURL(todoDir.appendingPathComponent("index.html"), allowingReadAccessTo: todoDir)
        self.webView = webView

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = appName()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear

        // Liquid Glass behind the whole window; the page stays below the (transparent) title bar
        // so the bar keeps dragging the window and the traffic lights don't cover the header.
        let content = NSView()
        content.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.contentView = content
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.addSubview(content)
            content.frame = blur.bounds
            content.autoresizingMask = [.width, .height]
            background = blur
        }
        window.contentView = background
        let layout = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: layout.topAnchor),
            webView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("TableroWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let msg = message.body as? [String: Any] else { return replyHandler(nil, "bad message") }
        let bodyText = msg["body"] as? String ?? ""
        let body = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any] ?? [:]
        let method = msg["method"] as? String ?? "GET"
        if msg["resource"] as? String == "config" {
            let reply = store.handleConfig(method: method, body: body)
            if method == "PUT" { DispatchQueue.main.async { self.nameChanged() } }
            return replyHandler(reply, nil)
        }
        if msg["resource"] as? String == "labels" {
            return replyHandler(store.handleLabels(method: method, body: body), nil)
        }
        replyHandler(store.handle(method: method, id: msg["id"] as? String ?? "", body: body), nil)
    }

    // Native panels for the page's alert()/confirm()/prompt() (delete note, change project)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Aceptar")
        alert.addButton(withTitle: "Cancelar")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "Aceptar")
        alert.addButton(withTitle: "Cancelar")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        showWindow()
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        appItem.submenu?.addItem(withTitle: "\(appName()) \(version)", action: nil, keyEquivalent: "")
        appItem.submenu?.addItem(withTitle: "Buscar actualizaciones…", action: #selector(checkForUpdates(_:)), keyEquivalent: "u")
        appItem.submenu?.addItem(.separator())
        appItem.submenu?.addItem(withTitle: "Ocultar \(appName())", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appItem.submenu?.addItem(.separator())
        appItem.submenu?.addItem(withTitle: "Salir de \(appName())", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        // Needed so ⌘C/⌘V/⌘Z/⌘A work inside the web view
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "Edición")
        editItem.submenu?.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        editItem.submenu?.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z")
        editItem.submenu?.addItem(.separator())
        editItem.submenu?.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editItem.submenu?.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editItem.submenu?.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu?.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Ventana")
        windowItem.submenu?.addItem(withTitle: "Minimizar", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu?.addItem(withTitle: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
