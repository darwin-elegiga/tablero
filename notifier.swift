// "Tablero.app": native window for the to-do board (WebKit, no background server) and the daily notification.
// The page talks to TodoStore through a WebKit message bridge; data lives in todos.json (shared with server.py).
// Launched with --notify by daily-reminder.sh. Build: build-notifier.sh
import AppKit
import UserNotifications
import WebKit

// Override with TABLERO_DIR; defaults to ~/tablero.
let todoDir = ProcessInfo.processInfo.environment["TABLERO_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tablero")
let statuses: Set<String> = ["todo", "doing", "qa", "done"]
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

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, WKScriptMessageHandlerWithReply, WKUIDelegate {
    let store = TodoStore()
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
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

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Tablero"
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
        appItem.submenu?.addItem(withTitle: "Ocultar Tablero", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appItem.submenu?.addItem(.separator())
        appItem.submenu?.addItem(withTitle: "Salir de Tablero", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
