import Cocoa

// Путь к проверенному движку (скачивание + конвертация + самолечение)
let SCRIPT = NSString(string: "~/yt2premiere/mac/yt2premiere.sh").expandingTildeInPath
let DEFAULT_OUT = NSString(string: "~/Movies/YouTube").expandingTildeInPath

let RES_TITLES = ["Макс. качество", "2160p (4K)", "1440p", "1080p", "720p", "480p", "360p"]
let RES_VALUES = [0, 2160, 1440, 1080, 720, 480, 360]
let FMT_TITLES = ["MP4 (H.264)", "ProRes (.mov)", "MP3 (звук)"]
let FMT_KEYS   = ["mp4", "prores", "mp3"]

final class QueueItem {
    let url: String
    let maxRes: Int      // 0 = макс
    let format: String   // mp4 | prores | mp3
    var status: String = "⏳ Ожидает"
    init(url: String, maxRes: Int, format: String) {
        self.url = url; self.maxRes = maxRes; self.format = format
    }
    var resLabel: String { maxRes == 0 ? "Макс." : "\(maxRes)p" }
    var fmtLabel: String {
        switch format { case "prores": return "ProRes"; case "mp3": return "MP3"; default: return "MP4" }
    }
    var displayURL: String {
        if url.count > 60 { return String(url.prefix(57)) + "…" }
        return url
    }
}

final class Controller: NSObject, NSTableViewDataSource {
    var window: NSWindow!
    var urlField: NSTextField!
    var resPopup: NSPopUpButton!
    var fmtPopup: NSPopUpButton!
    var addButton: NSButton!
    var removeButton: NSButton!
    var table: NSTableView!
    var folderField: NSTextField!
    var chooseButton: NSButton!
    var downloadButton: NSButton!
    var spinner: NSProgressIndicator!
    var statusLabel: NSTextField!
    var logView: NSTextView!

    var queue: [QueueItem] = []
    var currentProcess: Process?
    var idx = 0
    var pending = ""
    var lastOut = DEFAULT_OUT

    func makeLabel(_ s: String, _ f: NSRect, size: CGFloat = 13, bold: Bool = false, gray: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.frame = f
        t.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        if gray { t.textColor = .secondaryLabelColor }
        return t
    }

    func build() {
        let W: CGFloat = 660, H: CGFloat = 720
        window = NSWindow(contentRect: NSMakeRect(0, 0, W, H),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "yt2premiere — YouTube → Premiere Pro"
        window.center()
        let root = NSView(frame: NSMakeRect(0, 0, W, H))
        window.contentView = root

        root.addSubview(makeLabel("Скачивание YouTube для монтажа — очередь", NSMakeRect(20, 680, 620, 24), size: 16, bold: true))

        // ссылка
        root.addSubview(makeLabel("Ссылка на YouTube (можно несколько строк)", NSMakeRect(20, 656, 620, 16), bold: true))
        urlField = NSTextField(frame: NSMakeRect(20, 628, 620, 26))
        urlField.placeholderString = "Вставьте ссылку (⌘V или Ctrl+V) → выберите качество → «Добавить»"
        root.addSubview(urlField)

        // строка: качество + формат + добавить
        resPopup = NSPopUpButton(frame: NSMakeRect(20, 590, 180, 28), pullsDown: false)
        resPopup.addItems(withTitles: RES_TITLES)
        root.addSubview(resPopup)
        fmtPopup = NSPopUpButton(frame: NSMakeRect(210, 590, 180, 28), pullsDown: false)
        fmtPopup.addItems(withTitles: FMT_TITLES)
        root.addSubview(fmtPopup)
        addButton = NSButton(frame: NSMakeRect(400, 590, 240, 28))
        addButton.title = "＋ Добавить в очередь"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addToQueue)
        root.addSubview(addButton)

        // очередь
        root.addSubview(makeLabel("Очередь", NSMakeRect(20, 566, 620, 16), bold: true))
        let scroll = NSScrollView(frame: NSMakeRect(20, 380, 620, 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table = NSTableView(frame: scroll.bounds)
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        let cols: [(String, String, CGFloat)] = [
            ("url", "Видео", 290), ("res", "Качество", 90), ("fmt", "Формат", 80), ("status", "Статус", 140)
        ]
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        scroll.documentView = table
        root.addSubview(scroll)

        removeButton = NSButton(frame: NSMakeRect(20, 348, 240, 26))
        removeButton.title = "✕ Убрать выбранное"
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        root.addSubview(removeButton)

        // папка
        root.addSubview(makeLabel("Папка для сохранения", NSMakeRect(20, 322, 620, 16), bold: true))
        folderField = NSTextField(frame: NSMakeRect(20, 294, 470, 26))
        folderField.stringValue = DEFAULT_OUT
        root.addSubview(folderField)
        chooseButton = NSButton(frame: NSMakeRect(500, 292, 140, 30))
        chooseButton.title = "Выбрать…"
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        root.addSubview(chooseButton)

        // скачать
        downloadButton = NSButton(frame: NSMakeRect(20, 244, 620, 40))
        downloadButton.title = "⬇  Скачать всю очередь"
        downloadButton.bezelStyle = .rounded
        downloadButton.font = NSFont.boldSystemFont(ofSize: 15)
        downloadButton.keyEquivalent = "\r"
        downloadButton.target = self
        downloadButton.action = #selector(downloadAll)
        root.addSubview(downloadButton)

        // прогресс
        spinner = NSProgressIndicator(frame: NSMakeRect(20, 216, 18, 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        root.addSubview(spinner)
        statusLabel = makeLabel("Готов к работе.", NSMakeRect(44, 215, 596, 20), size: 12, gray: true)
        root.addSubview(statusLabel)

        // лог
        root.addSubview(makeLabel("Журнал", NSMakeRect(20, 190, 620, 16), bold: true))
        let logScroll = NSScrollView(frame: NSMakeRect(20, 16, 620, 168))
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.autohidesScrollers = true
        logView = NSTextView(frame: logScroll.bounds)
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSMakeSize(6, 6)
        logScroll.documentView = logView
        root.addSubview(logScroll)

        window.makeFirstResponder(urlField)
    }

    // ——— очередь ———
    @objc func addToQueue() {
        let raw = urlField.stringValue
        let parts = raw.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }).map { String($0) }
        let urls = parts.filter { $0.hasPrefix("http") }
        if urls.isEmpty {
            statusLabel.stringValue = "⚠️ Вставьте ссылку (должна начинаться с http)."
            NSSound.beep(); return
        }
        let res = RES_VALUES[max(0, resPopup.indexOfSelectedItem)]
        let fmt = FMT_KEYS[max(0, fmtPopup.indexOfSelectedItem)]
        for u in urls { queue.append(QueueItem(url: u, maxRes: res, format: fmt)) }
        urlField.stringValue = ""
        table.reloadData()
        statusLabel.stringValue = "В очереди: \(queue.count)"
    }

    @objc func removeSelected() {
        let sel = table.selectedRowIndexes
        guard !sel.isEmpty else { return }
        queue = queue.enumerated().filter { !sel.contains($0.offset) }.map { $0.element }
        table.reloadData()
        statusLabel.stringValue = "В очереди: \(queue.count)"
    }

    @objc func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Выбрать"
        if p.runModal() == .OK, let u = p.url { folderField.stringValue = u.path }
    }

    // ——— запуск очереди ———
    @objc func downloadAll() {
        guard !queue.isEmpty else { statusLabel.stringValue = "Очередь пуста — добавьте ссылки."; NSSound.beep(); return }
        if currentProcess != nil { return }
        var out = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { out = DEFAULT_OUT; folderField.stringValue = out }
        lastOut = out
        if !FileManager.default.fileExists(atPath: SCRIPT) {
            statusLabel.stringValue = "✖ Не найден движок: \(SCRIPT)"; return
        }
        for it in queue where !it.status.contains("Готово") { it.status = "⏳ Ожидает" }
        table.reloadData()
        setRunning(true)
        idx = 0
        step()
    }

    func step() {
        // пропускаем уже готовые
        while idx < queue.count && queue[idx].status.contains("Готово") { idx += 1 }
        if idx >= queue.count {
            setRunning(false)
            let ok = queue.filter { $0.status.contains("Готово") }.count
            statusLabel.stringValue = "✅ Завершено: \(ok) из \(queue.count). Папка открыта."
            NSWorkspace.shared.open(URL(fileURLWithPath: lastOut))
            return
        }
        let it = queue[idx]
        it.status = "⬇ Скачивание…"; table.reloadData()
        appendLog("\n──── [\(idx + 1)/\(queue.count)] \(it.url)  (\(it.resLabel), \(it.fmtLabel))\n")
        runEngine(for: it) { [weak self] ok in
            guard let self = self else { return }
            it.status = ok ? "✅ Готово" : "✖ Ошибка"
            self.table.reloadData()
            self.idx += 1
            self.step()
        }
    }

    func runEngine(for item: QueueItem, completion: @escaping (Bool) -> Void) {
        var args = [SCRIPT]
        if item.format == "prores" { args.append("--prores") }
        else if item.format == "mp3" { args.append("--mp3") }
        if item.maxRes > 0 { args += ["--max", String(item.maxRes)] }
        args += ["--out", lastOut, item.url]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pending = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; return }
            if let s = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self?.consume(s) }
            }
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let rest = self.clean(self.lastSeg(self.pending)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { self.appendLog(rest + "\n") }
                self.pending = ""
                self.currentProcess = nil
                completion(p.terminationStatus == 0)
            }
        }
        do {
            try proc.run()
            currentProcess = proc
        } catch {
            appendLog("✖ Ошибка запуска: \(error.localizedDescription)\n")
            completion(false)
        }
    }

    func setRunning(_ running: Bool) {
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        downloadButton.isEnabled = !running
        addButton.isEnabled = !running
        removeButton.isEnabled = !running
    }

    // ——— разбор вывода ———
    func consume(_ s: String) {
        pending += s
        while let r = pending.range(of: "\n") {
            let line = String(pending[..<r.lowerBound])
            pending.removeSubrange(pending.startIndex..<r.upperBound)
            let c = clean(lastSeg(line))
            if !c.trimmingCharacters(in: .whitespaces).isEmpty { appendLog(c + "\n") }
        }
        let live = clean(lastSeg(pending)).trimmingCharacters(in: .whitespaces)
        if !live.isEmpty { statusLabel.stringValue = live }
    }

    func lastSeg(_ s: String) -> String {
        if let r = s.range(of: "\r", options: .backwards) { return String(s[r.upperBound...]) }
        return s
    }

    func clean(_ s: String) -> String {
        return s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    func appendLog(_ s: String) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor
        ])
        logView.textStorage?.append(attr)
        logView.scrollToEndOfDocument(nil)
    }

    // ——— NSTableViewDataSource ———
    func numberOfRows(in tableView: NSTableView) -> Int { queue.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < queue.count else { return nil }
        let it = queue[row]
        switch tableColumn?.identifier.rawValue {
        case "url": return it.displayURL
        case "res": return it.resLabel
        case "fmt": return it.fmtLabel
        case "status": return it.status
        default: return nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()

    func applicationDidFinishLaunching(_ n: Notification) {
        makeMenu()
        controller.build()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Ctrl+V / Ctrl+C / Ctrl+X (привычка с Windows) — в дополнение к ⌘V
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control {
                switch e.charactersIgnoringModifiers {
                case "v": NSApp.sendAction(Selector(("paste:")), to: nil, from: nil); return nil
                case "c": NSApp.sendAction(Selector(("copy:")), to: nil, from: nil); return nil
                case "x": NSApp.sendAction(Selector(("cut:")), to: nil, from: nil); return nil
                case "a": NSApp.sendAction(Selector(("selectAll:")), to: nil, from: nil); return nil
                default: break
                }
            }
            return e
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func makeMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Скрыть", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
