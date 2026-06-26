import Cocoa

// Самодостаточное приложение: инструменты берём системные (Homebrew) если есть,
// иначе скачиваем yt-dlp + статический ffmpeg/ffprobe в Application Support.
let RES_TITLES = ["Макс. качество", "2160p (4K)", "1440p", "1080p", "720p", "480p", "360p"]
let RES_VALUES = [0, 2160, 1440, 1080, 720, 480, 360]
let FMT_TITLES = ["MP4 (H.264)", "ProRes (.mov)", "MP3 (звук)"]
let FMT_KEYS   = ["mp4", "prores", "mp3"]
let DEFAULT_OUT = (NSHomeDirectory() as NSString).appendingPathComponent("Movies/YouTube")

// ───────────────────────────── инструменты ──────────────────────────────────
final class Tools {
    static let binDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/yt2premiere/bin")
    static var ytDlp = ""
    static var ffmpeg = ""
    static var ffprobe = ""

    static func which(_ name: String) -> String? {
        for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func download(_ urlStr: String, to path: String) throws {
        guard let url = URL(string: urlStr) else { throw NSError(domain: "yt2", code: 1) }
        let data = try Data(contentsOf: url)
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func setExec(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    static func runSync(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    static func findFile(_ name: String, in dir: String) -> String? {
        guard let en = FileManager.default.enumerator(atPath: dir) else { return nil }
        for case let f as String in en where (f as NSString).lastPathComponent == name {
            return dir + "/" + f
        }
        return nil
    }

    static func fromZip(_ name: String, _ url: String, _ log: (String) -> Void) throws -> String {
        let dest = binDir + "/" + name
        if FileManager.default.isExecutableFile(atPath: dest) { return dest }
        log("Скачиваю \(name) (~25 МБ, разово)…")
        let zip = NSTemporaryDirectory() + "yt2prem_\(name).zip"
        try download(url, to: zip)
        let ext = NSTemporaryDirectory() + "yt2prem_\(name)_x"
        try? FileManager.default.removeItem(atPath: ext)
        runSync("/usr/bin/ditto", ["-x", "-k", zip, ext])
        if let found = findFile(name, in: ext) {
            try? FileManager.default.removeItem(atPath: dest)
            try FileManager.default.copyItem(atPath: found, toPath: dest)
            setExec(dest)
        }
        try? FileManager.default.removeItem(atPath: zip)
        try? FileManager.default.removeItem(atPath: ext)
        return dest
    }

    static func ensure(_ log: (String) -> Void) throws {
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        if let s = which("yt-dlp") { ytDlp = s }
        else {
            let local = binDir + "/yt-dlp"
            if !FileManager.default.isExecutableFile(atPath: local) {
                log("Скачиваю yt-dlp (разово)…")
                try download("https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos", to: local)
                setExec(local)
            }
            ytDlp = local
        }
        if let s = which("ffmpeg") { ffmpeg = s }
        else { ffmpeg = try fromZip("ffmpeg", "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip", log) }
        if let s = which("ffprobe") { ffprobe = s }
        else { ffprobe = try fromZip("ffprobe", "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip", log) }
    }
}

final class QueueItem {
    let url: String
    let maxRes: Int
    let format: String
    var status = "⏳ Ожидает"
    init(url: String, maxRes: Int, format: String) { self.url = url; self.maxRes = maxRes; self.format = format }
    var resLabel: String { maxRes == 0 ? "Макс." : "\(maxRes)p" }
    var fmtLabel: String { format == "prores" ? "ProRes" : format == "mp3" ? "MP3" : "MP4" }
    var displayURL: String { url.count > 60 ? String(url.prefix(57)) + "…" : url }
}

final class Controller: NSObject, NSTableViewDataSource {
    var window: NSWindow!
    var urlField: NSTextField!
    var resPopup: NSPopUpButton!
    var fmtPopup: NSPopUpButton!
    var addButton, removeButton, chooseButton, downloadButton: NSButton!
    var table: NSTableView!
    var folderField: NSTextField!
    var spinner: NSProgressIndicator!
    var statusLabel: NSTextField!
    var logView: NSTextView!

    var queue: [QueueItem] = []
    var pending = ""
    var lastOut = DEFAULT_OUT
    var updatedYtDlp = false
    var cachedEnc: String?

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
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "yt2premiere — YouTube → Premiere Pro"
        window.center()
        let root = NSView(frame: NSMakeRect(0, 0, W, H))
        window.contentView = root

        root.addSubview(makeLabel("Скачивание YouTube для монтажа — очередь", NSMakeRect(20, 680, 620, 24), size: 16, bold: true))
        root.addSubview(makeLabel("Ссылка на YouTube (можно несколько строк)", NSMakeRect(20, 656, 620, 18), bold: true))
        urlField = NSTextField(frame: NSMakeRect(20, 628, 620, 26))
        urlField.placeholderString = "Вставьте ссылку (⌘V или Ctrl+V) → выберите качество → «Добавить»"
        root.addSubview(urlField)

        resPopup = NSPopUpButton(frame: NSMakeRect(20, 590, 180, 28), pullsDown: false)
        resPopup.addItems(withTitles: RES_TITLES); root.addSubview(resPopup)
        fmtPopup = NSPopUpButton(frame: NSMakeRect(210, 590, 180, 28), pullsDown: false)
        fmtPopup.addItems(withTitles: FMT_TITLES); root.addSubview(fmtPopup)
        addButton = NSButton(frame: NSMakeRect(400, 590, 240, 28))
        addButton.title = "＋ Добавить в очередь"; addButton.bezelStyle = .rounded
        addButton.target = self; addButton.action = #selector(addToQueue); root.addSubview(addButton)

        root.addSubview(makeLabel("Очередь", NSMakeRect(20, 566, 620, 18), bold: true))
        let scroll = NSScrollView(frame: NSMakeRect(20, 380, 620, 180))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table = NSTableView(frame: scroll.bounds)
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 22
        for (id, title, w) in [("url", "Видео", CGFloat(290)), ("res", "Качество", 90), ("fmt", "Формат", 80), ("status", "Статус", 140)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self; scroll.documentView = table; root.addSubview(scroll)

        removeButton = NSButton(frame: NSMakeRect(20, 348, 240, 26))
        removeButton.title = "✕ Убрать выбранное"; removeButton.bezelStyle = .rounded
        removeButton.target = self; removeButton.action = #selector(removeSelected); root.addSubview(removeButton)

        root.addSubview(makeLabel("Папка для сохранения", NSMakeRect(20, 322, 620, 18), bold: true))
        folderField = NSTextField(frame: NSMakeRect(20, 294, 470, 26))
        folderField.stringValue = DEFAULT_OUT; root.addSubview(folderField)
        chooseButton = NSButton(frame: NSMakeRect(500, 292, 140, 30))
        chooseButton.title = "Выбрать…"; chooseButton.bezelStyle = .rounded
        chooseButton.target = self; chooseButton.action = #selector(chooseFolder); root.addSubview(chooseButton)

        downloadButton = NSButton(frame: NSMakeRect(20, 244, 620, 40))
        downloadButton.title = "⬇  Скачать всю очередь"; downloadButton.bezelStyle = .rounded
        downloadButton.font = NSFont.boldSystemFont(ofSize: 15); downloadButton.keyEquivalent = "\r"
        downloadButton.target = self; downloadButton.action = #selector(downloadAll); root.addSubview(downloadButton)

        spinner = NSProgressIndicator(frame: NSMakeRect(20, 216, 18, 18))
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        root.addSubview(spinner)
        statusLabel = makeLabel("Готов к работе.", NSMakeRect(44, 215, 596, 20), size: 12, gray: true)
        root.addSubview(statusLabel)

        root.addSubview(makeLabel("Журнал", NSMakeRect(20, 190, 620, 16), bold: true))
        let logScroll = NSScrollView(frame: NSMakeRect(20, 16, 620, 168))
        logScroll.hasVerticalScroller = true; logScroll.borderType = .bezelBorder; logScroll.autohidesScrollers = true
        logView = NSTextView(frame: logScroll.bounds)
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSMakeSize(6, 6)
        logScroll.documentView = logView; root.addSubview(logScroll)

        window.makeFirstResponder(urlField)
    }

    // ——— очередь ———
    @objc func addToQueue() {
        let parts = urlField.stringValue.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }).map(String.init)
        let urls = parts.filter { $0.hasPrefix("http") }
        if urls.isEmpty { statusLabel.stringValue = "⚠️ Вставьте ссылку (должна начинаться с http)."; NSSound.beep(); return }
        let res = RES_VALUES[max(0, resPopup.indexOfSelectedItem)]
        let fmt = FMT_KEYS[max(0, fmtPopup.indexOfSelectedItem)]
        for u in urls { queue.append(QueueItem(url: u, maxRes: res, format: fmt)) }
        urlField.stringValue = ""; table.reloadData(); statusLabel.stringValue = "В очереди: \(queue.count)"
    }

    @objc func removeSelected() {
        let sel = table.selectedRowIndexes
        if sel.isEmpty { return }
        queue = queue.enumerated().filter { !sel.contains($0.offset) }.map { $0.element }
        table.reloadData(); statusLabel.stringValue = "В очереди: \(queue.count)"
    }

    @objc func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.prompt = "Выбрать"
        if p.runModal() == .OK, let u = p.url { folderField.stringValue = u.path }
    }

    func setRunning(_ r: Bool) {
        if r { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        downloadButton.isEnabled = !r; addButton.isEnabled = !r; removeButton.isEnabled = !r
    }

    @objc func downloadAll() {
        if queue.isEmpty { statusLabel.stringValue = "Очередь пуста — добавьте ссылки."; NSSound.beep(); return }
        var out = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { out = DEFAULT_OUT; folderField.stringValue = out }
        lastOut = out
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for it in queue where !it.status.contains("Готово") { it.status = "⏳ Ожидает" }
        table.reloadData(); logView.string = ""; updatedYtDlp = false
        setRunning(true)

        DispatchQueue.global(qos: .userInitiated).async {
            do { try Tools.ensure { m in self.ui { self.appendLog(m + "\n") } } }
            catch {
                self.ui { self.appendLog("✖ Не удалось получить инструменты: \(error.localizedDescription)\n"); self.statusLabel.stringValue = "✖ Ошибка"; self.setRunning(false) }
                return
            }
            for (i, it) in self.queue.enumerated() {
                self.ui {
                    it.status = "⬇ Скачивание…"; self.table.reloadData()
                    self.statusLabel.stringValue = "Скачивание \(i + 1)/\(self.queue.count)…"
                    self.appendLog("\n──── [\(i + 1)/\(self.queue.count)] \(it.url)  (\(it.resLabel), \(it.fmtLabel))\n")
                }
                let ok = self.processItem(it)
                self.ui { it.status = ok ? "✅ Готово" : "✖ Ошибка"; self.table.reloadData() }
            }
            self.ui {
                self.setRunning(false)
                let ok = self.queue.filter { $0.status.contains("Готово") }.count
                self.statusLabel.stringValue = "✅ Завершено: \(ok) из \(self.queue.count). Папка открыта."
                NSWorkspace.shared.open(URL(fileURLWithPath: self.lastOut))
            }
        }
    }

    // ——— движок (фоновый поток) ———
    func ui(_ a: @escaping () -> Void) { if Thread.isMainThread { a() } else { DispatchQueue.main.async(execute: a) } }

    func runTool(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pending = ""
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            if let s = String(data: d, encoding: .utf8) { DispatchQueue.main.async { self.consume(s) } }
        }
        do { try p.run() } catch { return 1 }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return p.terminationStatus
    }

    func heal(_ args: [String]) -> Bool {
        if runTool(Tools.ytDlp, args) == 0 { return true }
        ui { self.appendLog("Сбой загрузки — повтор…\n") }; Thread.sleep(forTimeInterval: 3)
        if runTool(Tools.ytDlp, args) == 0 { return true }
        if !updatedYtDlp { updatedYtDlp = true; ui { self.appendLog("Обновляю yt-dlp…\n") }; _ = runTool(Tools.ytDlp, ["-U"]) }
        if runTool(Tools.ytDlp, args) == 0 { return true }
        ui { self.appendLog("Обходной режим (смена клиента YouTube)…\n") }
        return runTool(Tools.ytDlp, ["--extractor-args", "youtube:player_client=tv,web,android,ios"] + args) == 0
    }

    func processItem(_ it: QueueItem) -> Bool {
        let ffDir = (Tools.ffmpeg as NSString).deletingLastPathComponent
        if it.format == "mp3" {
            let out = lastOut + "/%(title)s [%(id)s].%(ext)s"
            return heal(["-x", "--audio-format", "mp3", "--audio-quality", "0", "--ffmpeg-location", ffDir, "-o", out, it.url])
        }
        let fmt = it.maxRes > 0 ? "bv*[height<=\(it.maxRes)]+ba/b[height<=\(it.maxRes)]/bv*+ba/b" : "bv*+ba/b"
        let work = NSTemporaryDirectory() + "yt2prem_" + String(UUID().uuidString.prefix(8))
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        let tmpl = work + "/%(title)s [%(id)s].%(ext)s"
        if !heal(["-f", fmt, "--merge-output-format", "mkv", "--ffmpeg-location", ffDir, "-o", tmpl, it.url]) { return false }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []).filter {
            $0.hasSuffix(".mkv") || $0.hasSuffix(".mp4") || $0.hasSuffix(".webm") || $0.hasSuffix(".mov")
        }
        if files.isEmpty { return false }
        for f in files { transcode(work + "/" + f, it) }
        return true
    }

    func probe(_ src: String) -> Int {
        let p = Process(); p.executableURL = URL(fileURLWithPath: Tools.ffprobe)
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=height", "-of", "csv=p=0", src]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return 1080 }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let s = (String(data: d, encoding: .utf8) ?? "").split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return Int(s) ?? 1080
    }

    func enc() -> String {
        if let c = cachedEnc { return c }
        let p = Process(); p.executableURL = URL(fileURLWithPath: Tools.ffmpeg); p.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        var o = ""
        do { try p.run(); o = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit() } catch {}
        let e = o.contains("h264_videotoolbox") ? "h264_videotoolbox" : "libx264"
        cachedEnc = e; return e
    }

    func transcode(_ src: String, _ it: QueueItem) {
        let h = probe(src)
        let base = ((src as NSString).lastPathComponent as NSString).deletingPathExtension
        if it.format == "prores" {
            let out = lastOut + "/" + base + ".mov"
            ui { self.appendLog("ProRes 422 HQ (\(h)p) → \(base).mov\n") }
            let rc = runTool(Tools.ffmpeg, ["-y", "-hide_banner", "-loglevel", "warning", "-stats", "-i", src,
                "-c:v", "prores_videotoolbox", "-profile:v", "hq", "-pix_fmt", "yuv422p10le", "-c:a", "pcm_s16le", out])
            if rc != 0 {
                _ = runTool(Tools.ffmpeg, ["-y", "-hide_banner", "-loglevel", "warning", "-stats", "-i", src,
                    "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-vendor", "apl0", "-c:a", "pcm_s16le", out])
            }
        } else {
            let vb = h >= 2160 ? "45M" : h >= 1440 ? "24M" : h >= 1080 ? "14M" : h >= 720 ? "8M" : "5M"
            let venc = enc()
            let out = lastOut + "/" + base + ".mp4"
            ui { self.appendLog("MP4 H.264 / \(venc) (\(h)p, \(vb)) → \(base).mp4\n") }
            _ = runTool(Tools.ffmpeg, ["-y", "-hide_banner", "-loglevel", "warning", "-stats", "-i", src,
                "-c:v", venc, "-b:v", vb, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "320k", "-movflags", "+faststart", out])
        }
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
    func clean(_ s: String) -> String { s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
    func appendLog(_ s: String) {
        logView.textStorage?.append(NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor]))
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
