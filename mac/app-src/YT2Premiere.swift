import Cocoa

// Путь к проверенному движку (скачивание + конвертация + самолечение)
let SCRIPT = NSString(string: "~/yt2premiere/mac/yt2premiere.sh").expandingTildeInPath
let DEFAULT_OUT = NSString(string: "~/Movies/YouTube").expandingTildeInPath

final class Controller: NSObject {
    var window: NSWindow!
    var urlField: NSTextField!
    var formatPopup: NSPopUpButton!
    var folderField: NSTextField!
    var downloadButton: NSButton!
    var spinner: NSProgressIndicator!
    var statusLabel: NSTextField!
    var logView: NSTextView!
    var process: Process?
    var pending = ""
    var lastOut = DEFAULT_OUT

    // ——— вспомогательные ———
    func makeLabel(_ s: String, _ f: NSRect, size: CGFloat = 13, bold: Bool = false, gray: Bool = false) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.frame = f
        t.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        if gray { t.textColor = .secondaryLabelColor }
        return t
    }

    func build() {
        let W: CGFloat = 600, H: CGFloat = 620
        window = NSWindow(contentRect: NSMakeRect(0, 0, W, H),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "yt2premiere — YouTube → Premiere Pro"
        window.center()
        let root = NSView(frame: NSMakeRect(0, 0, W, H))
        window.contentView = root

        root.addSubview(makeLabel("Скачать видео с YouTube для монтажа", NSMakeRect(20, 582, 560, 24), size: 16, bold: true))

        // 1. ссылка
        root.addSubview(makeLabel("1. Ссылка на YouTube", NSMakeRect(20, 552, 560, 18), bold: true))
        urlField = NSTextField(frame: NSMakeRect(20, 524, 560, 26))
        urlField.placeholderString = "Вставьте ссылку (⌘V) и нажмите «Скачать»"
        root.addSubview(urlField)

        // 2. формат
        root.addSubview(makeLabel("2. Формат", NSMakeRect(20, 490, 560, 18), bold: true))
        formatPopup = NSPopUpButton(frame: NSMakeRect(20, 458, 320, 28), pullsDown: false)
        formatPopup.addItems(withTitles: [
            "MP4 (H.264) — универсально",
            "ProRes (.mov) — лучший для монтажа",
            "MP3 — только звук"
        ])
        root.addSubview(formatPopup)

        // 3. папка
        root.addSubview(makeLabel("3. Папка для сохранения", NSMakeRect(20, 424, 560, 18), bold: true))
        folderField = NSTextField(frame: NSMakeRect(20, 396, 430, 26))
        folderField.stringValue = DEFAULT_OUT
        root.addSubview(folderField)
        let choose = NSButton(frame: NSMakeRect(458, 394, 122, 30))
        choose.title = "Выбрать…"
        choose.bezelStyle = .rounded
        choose.target = self
        choose.action = #selector(chooseFolder)
        root.addSubview(choose)

        // кнопка скачать
        downloadButton = NSButton(frame: NSMakeRect(20, 344, 560, 42))
        downloadButton.title = "⬇  Скачать"
        downloadButton.bezelStyle = .rounded
        downloadButton.font = NSFont.boldSystemFont(ofSize: 15)
        downloadButton.keyEquivalent = "\r"
        downloadButton.target = self
        downloadButton.action = #selector(startDownload)
        root.addSubview(downloadButton)

        // прогресс
        spinner = NSProgressIndicator(frame: NSMakeRect(20, 314, 20, 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        root.addSubview(spinner)
        statusLabel = makeLabel("Готов к работе.", NSMakeRect(48, 313, 532, 20), size: 12, gray: true)
        root.addSubview(statusLabel)

        // лог
        let scroll = NSScrollView(frame: NSMakeRect(20, 16, 560, 288))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        logView = NSTextView(frame: scroll.bounds)
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSMakeSize(6, 6)
        scroll.documentView = logView
        root.addSubview(scroll)

        window.makeFirstResponder(urlField)
    }

    // ——— действия ———
    @objc func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Выбрать"
        if p.runModal() == .OK, let u = p.url { folderField.stringValue = u.path }
    }

    @objc func startDownload() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            statusLabel.stringValue = "⚠️ Сначала вставьте ссылку на YouTube."
            NSSound.beep()
            return
        }
        var out = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { out = DEFAULT_OUT; folderField.stringValue = out }
        lastOut = out

        if !FileManager.default.fileExists(atPath: SCRIPT) {
            statusLabel.stringValue = "✖ Не найден движок: \(SCRIPT)"
            return
        }

        var args = [SCRIPT]
        switch formatPopup.indexOfSelectedItem {
        case 1: args.append("--prores")
        case 2: args.append("--mp3")
        default: break
        }
        args += ["--out", out, url]

        // UI в режим «работаю»
        logView.string = ""
        pending = ""
        statusLabel.stringValue = "Запускаю…"
        downloadButton.isEnabled = false
        spinner.startAnimation(nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        // GUI-приложения не наследуют PATH из шелла — добавляем brew/системные пути
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
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
                self.spinner.stopAnimation(nil)
                self.downloadButton.isEnabled = true
                let rest = self.clean(self.lastSeg(self.pending)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { self.appendLog(rest + "\n") }
                self.pending = ""
                if p.terminationStatus == 0 {
                    self.statusLabel.stringValue = "✅ Готово! Папка открыта в Finder."
                    NSWorkspace.shared.open(URL(fileURLWithPath: self.lastOut))
                } else {
                    self.statusLabel.stringValue = "✖ Не удалось. Подробности в логе ниже."
                }
                self.process = nil
            }
        }

        do {
            try proc.run()
            self.process = proc
            statusLabel.stringValue = "Скачиваю…"
        } catch {
            spinner.stopAnimation(nil)
            downloadButton.isEnabled = true
            statusLabel.stringValue = "✖ Ошибка запуска: \(error.localizedDescription)"
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

    // текст после последнего \r (эмуляция перезаписи строки в терминале)
    func lastSeg(_ s: String) -> String {
        if let r = s.range(of: "\r", options: .backwards) { return String(s[r.upperBound...]) }
        return s
    }

    // снять ANSI-цвета
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    func applicationDidFinishLaunching(_ n: Notification) {
        controller.build()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
