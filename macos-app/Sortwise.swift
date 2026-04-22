import Cocoa
import UserNotifications

struct DiskItem {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let isDir: Bool

    var displaySize: String {
        let gb = Double(sizeBytes) / 1_000_000_000
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(sizeBytes) / 1_000_000
        if mb >= 1.0 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(sizeBytes) / 1_000)
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var fileCountItem: NSMenuItem!
    var lastRunItem: NSMenuItem!
    var autoTidyItem: NSMenuItem!
    var aiToggleItem: NSMenuItem!
    var dirToggles: [String: NSMenuItem] = [:]
    var refreshTimer: Timer?

    // Disk usage
    var diskHeaderItem: NSMenuItem!
    var diskSubmenu: NSMenu!
    var diskItems: [DiskItem] = []
    var diskScanInProgress = false

    let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sortwise/config.json")
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sortwise/last-run.json")
    let cliPath: String = {
        // Check common pipx locations, then fall back to PATH lookup
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/sortwise",
            "/opt/homebrew/bin/sortwise",
            "/usr/local/bin/sortwise",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Fall back to PATH via shell
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which sortwise"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return "\(home)/.local/bin/sortwise"
    }()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "Sortwise") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = img.withSymbolConfiguration(config)
            }
        }

        buildMenu()
        statusItem.menu = statusMenu
        refreshStatus()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshStatus()
            self?.checkAutoTidy()
        }
    }

    func buildMenu() {
        statusMenu = NSMenu()
        statusMenu.delegate = self

        fileCountItem = NSMenuItem(title: "Scanning...", action: nil, keyEquivalent: "")
        fileCountItem.isEnabled = false
        statusMenu.addItem(fileCountItem)

        lastRunItem = NSMenuItem(title: "Last run: never", action: nil, keyEquivalent: "")
        lastRunItem.isEnabled = false
        statusMenu.addItem(lastRunItem)

        statusMenu.addItem(.separator())

        let tidyItem = NSMenuItem(title: "Tidy Now", action: #selector(tidyNow), keyEquivalent: "t")
        tidyItem.target = self
        statusMenu.addItem(tidyItem)

        let previewItem = NSMenuItem(title: "Preview...", action: #selector(preview), keyEquivalent: "p")
        previewItem.target = self
        statusMenu.addItem(previewItem)

        statusMenu.addItem(.separator())

        // Disk Usage section
        diskHeaderItem = NSMenuItem(title: "💾 Disk Usage", action: nil, keyEquivalent: "")
        diskHeaderItem.isEnabled = false
        statusMenu.addItem(diskHeaderItem)

        diskSubmenu = NSMenu()
        let diskMenuItem = NSMenuItem(title: "Space Hogs", action: nil, keyEquivalent: "")
        diskMenuItem.submenu = diskSubmenu
        // We won't use a submenu — we'll insert items directly into the main menu
        // after diskHeaderItem. We track insertion with a tag range.

        statusMenu.addItem(.separator())

        // Watched folders
        let foldersHeader = NSMenuItem(title: "WATCHED FOLDERS", action: nil, keyEquivalent: "")
        foldersHeader.isEnabled = false
        foldersHeader.attributedTitle = NSAttributedString(
            string: "WATCHED FOLDERS",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        statusMenu.addItem(foldersHeader)

        let watchedDirs = loadWatchedDirs()
        for dirName in ["Downloads", "Documents", "Desktop"] {
            let item = NSMenuItem(title: dirName, action: #selector(toggleWatchedDir(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dirName
            item.state = (watchedDirs[dirName] ?? (dirName == "Downloads")) ? .on : .off
            statusMenu.addItem(item)
            dirToggles[dirName] = item
        }

        statusMenu.addItem(.separator())

        autoTidyItem = NSMenuItem(title: "Auto-tidy (every 4h)", action: #selector(toggleAutoTidy), keyEquivalent: "")
        autoTidyItem.target = self
        autoTidyItem.state = loadConfigBool("auto_enabled", default: true) ? .on : .off
        statusMenu.addItem(autoTidyItem)

        aiToggleItem = NSMenuItem(title: "AI Classification", action: #selector(toggleAI), keyEquivalent: "")
        aiToggleItem.target = self
        aiToggleItem.state = loadConfigBool("use_ai", default: true) ? .on : .off
        statusMenu.addItem(aiToggleItem)

        statusMenu.addItem(.separator())

        let openDownloads = NSMenuItem(title: "Open Downloads", action: #selector(openDownloadsFolder), keyEquivalent: "o")
        openDownloads.target = self
        statusMenu.addItem(openDownloads)

        let openConfig = NSMenuItem(title: "Open Config", action: #selector(openConfigFolder), keyEquivalent: "")
        openConfig.target = self
        statusMenu.addItem(openConfig)

        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    // MARK: - Menu Delegate

    let diskItemTag = 9000

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatus()
        scanDisk()
    }

    // MARK: - Disk Usage

    func scanDisk() {
        guard !diskScanInProgress else { return }
        diskScanInProgress = true
        diskHeaderItem.title = "💾 Scanning disk..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Overall disk space
            let home = FileManager.default.homeDirectoryForCurrentUser
            var totalDisk: Int64 = 0
            var usedDisk: Int64 = 0
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home.path) {
                let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
                let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                totalDisk = total
                usedDisk = total - free
            }

            // Scan large directories — home top-level + key subdirectories
            var items: [DiskItem] = []

            // Home top-level folders
            let homeDirs = (try? FileManager.default.contentsOfDirectory(
                at: home, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for dirURL in homeDirs {
                let isDir = (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDir { continue }
                let size = self.duSize(path: dirURL.path)
                if size > 100_000_000 { // > 100 MB
                    items.append(DiskItem(url: dirURL, name: "~/" + dirURL.lastPathComponent, sizeBytes: size, isDir: true))
                }
            }

            // Also scan key hidden/system dirs that are common space hogs
            let extraPaths = [
                ".Trash", "Library/Caches", "Library/Application Support",
                "Library/Developer", "Library/Containers",
            ]
            for rel in extraPaths {
                let url = home.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let size = self.duSize(path: url.path)
                if size > 100_000_000 {
                    items.append(DiskItem(url: url, name: "~/" + rel, sizeBytes: size, isDir: true))
                }
            }

            // Find largest individual files (>500MB) under home
            let bigFiles = self.findLargeFiles(root: home.path, minBytes: 500_000_000, limit: 5)
            items.append(contentsOf: bigFiles)

            items.sort { $0.sizeBytes > $1.sizeBytes }

            DispatchQueue.main.async {
                self.updateDiskMenu(items: items, totalDisk: totalDisk, usedDisk: usedDisk)
                self.diskScanInProgress = false
            }
        }
    }

    func duSize(path: String) -> Int64 {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               let kb = output.split(separator: "\t").first,
               let val = Int64(kb) {
                return val * 1024
            }
        } catch {}
        return 0
    }

    func findLargeFiles(root: String, minBytes: Int64, limit: Int) -> [DiskItem] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [
            root, "-type", "f", "-size", "+\(minBytes / 1_000_000)M",
            "-not", "-path", "*/Library/*",
            "-not", "-path", "*/.Trash/*",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var results: [DiskItem] = []
            for line in output.components(separatedBy: "\n") where !line.isEmpty {
                let url = URL(fileURLWithPath: line)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: line),
                   let size = attrs[.size] as? Int64 {
                    let display = line.hasPrefix(home)
                        ? "~" + line.dropFirst(home.count)
                        : line
                    results.append(DiskItem(url: url, name: String(display), sizeBytes: size, isDir: false))
                }
            }
            results.sort { $0.sizeBytes > $1.sizeBytes }
            return Array(results.prefix(limit))
        } catch {
            return []
        }
    }

    func updateDiskMenu(items: [DiskItem], totalDisk: Int64, usedDisk: Int64) {
        // Remove old disk items
        while let old = statusMenu.item(withTag: diskItemTag) {
            statusMenu.removeItem(old)
        }

        // Update header
        let usedGB = String(format: "%.0f", Double(usedDisk) / 1_000_000_000)
        let totalGB = String(format: "%.0f", Double(totalDisk) / 1_000_000_000)
        let pct = totalDisk > 0 ? Int(Double(usedDisk) / Double(totalDisk) * 100) : 0
        diskHeaderItem.title = "💾 \(usedGB) / \(totalGB) GB used (\(pct)%)"

        let headerIndex = statusMenu.index(of: diskHeaderItem)
        guard headerIndex != -1 else { return }
        var insertIndex = headerIndex + 1

        self.diskItems = items

        // Separate folders and files
        let folders = items.filter { $0.isDir }.prefix(8)
        let files = items.filter { !$0.isDir }.prefix(5)

        if !folders.isEmpty {
            let folderHeader = NSMenuItem(title: "Largest Folders", action: nil, keyEquivalent: "")
            folderHeader.tag = diskItemTag
            folderHeader.isEnabled = false
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            folderHeader.attributedTitle = NSAttributedString(
                string: "LARGEST FOLDERS",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
            statusMenu.insertItem(folderHeader, at: insertIndex)
            insertIndex += 1

            for (i, item) in folders.enumerated() {
                let menuItem = makeDiskMenuItem(item: item, index: i)
                statusMenu.insertItem(menuItem, at: insertIndex)
                insertIndex += 1
            }
        }

        if !files.isEmpty {
            let fileHeader = NSMenuItem(title: "Large Files", action: nil, keyEquivalent: "")
            fileHeader.tag = diskItemTag
            fileHeader.isEnabled = false
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            fileHeader.attributedTitle = NSAttributedString(
                string: "LARGE FILES (>500 MB)",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            )
            statusMenu.insertItem(fileHeader, at: insertIndex)
            insertIndex += 1

            for (i, item) in files.enumerated() {
                let menuItem = makeDiskMenuItem(item: item, index: folders.count + i)
                statusMenu.insertItem(menuItem, at: insertIndex)
                insertIndex += 1
            }
        }

        if folders.isEmpty && files.isEmpty {
            let emptyItem = NSMenuItem(title: "  No large items found", action: nil, keyEquivalent: "")
            emptyItem.tag = diskItemTag
            emptyItem.isEnabled = false
            statusMenu.insertItem(emptyItem, at: insertIndex)
        }
    }

    func makeDiskMenuItem(item: DiskItem, index: Int) -> NSMenuItem {
        // Build a nice attributed string: icon + name (regular) + size (bold, right-ish)
        let icon = item.isDir ? "📁" : "📄"
        let shortName: String
        let name = item.name
        // Truncate long paths
        if name.count > 30 {
            let parts = name.components(separatedBy: "/")
            if parts.count > 3 {
                shortName = parts[0] + "/.../" + parts[parts.count - 1]
            } else {
                shortName = String(name.suffix(30))
            }
        } else {
            shortName = name
        }

        let title = "\(icon)  \(shortName)    \(item.displaySize)"

        let menuItem = NSMenuItem(title: title, action: #selector(revealDiskItem(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.tag = diskItemTag
        menuItem.representedObject = item.url
        menuItem.toolTip = "\(item.name) — \(item.displaySize)\nClick to reveal in Finder"

        // Style with attributed string for alignment
        let full = NSMutableAttributedString()

        let nameStr = NSAttributedString(string: "\(icon)  \(shortName)  ", attributes: [
            .font: NSFont.menuFont(ofSize: 13),
        ])
        full.append(nameStr)

        let sizeStr = NSAttributedString(string: item.displaySize, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: sizeColor(bytes: item.sizeBytes),
        ])
        full.append(sizeStr)

        menuItem.attributedTitle = full
        return menuItem
    }

    func sizeColor(bytes: Int64) -> NSColor {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 10 { return NSColor.systemRed }
        if gb >= 5 { return NSColor.systemOrange }
        if gb >= 1 { return NSColor.systemYellow }
        return NSColor.secondaryLabelColor
    }

    @objc func revealDiskItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Tidy Actions

    @objc func tidyNow() {
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: "Working...") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = img.withSymbolConfiguration(config)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCLI(args: ["--move"])
            DispatchQueue.main.async {
                self.setDefaultIcon()
                self.refreshStatus()
                self.sendNotification(title: "Sortwise", body: self.extractSummary(result))
            }
        }
    }

    @objc func preview() {
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: "Working...") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = img.withSymbolConfiguration(config)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCLI(args: [])
            DispatchQueue.main.async {
                self.setDefaultIcon()
                self.sendNotification(title: "Sortwise — Preview", body: self.extractSummary(result))
            }
        }
    }

    @objc func toggleWatchedDir(_ sender: NSMenuItem) {
        guard let dirName = sender.representedObject as? String else { return }
        let current = sender.state == .on
        sender.state = current ? .off : .on
        saveWatchedDir(dirName, enabled: !current)
        refreshStatus()
    }

    @objc func toggleAutoTidy() {
        let current = autoTidyItem.state == .on
        autoTidyItem.state = current ? .off : .on
        saveConfigBool("auto_enabled", value: !current)
    }

    @objc func toggleAI() {
        let current = aiToggleItem.state == .on
        aiToggleItem.state = current ? .off : .on
        saveConfigBool("use_ai", value: !current)
    }

    @objc func openDownloadsFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        NSWorkspace.shared.open(url)
    }

    @objc func openConfigFolder() {
        let url = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Status

    func refreshStatus() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let watched = loadWatchedDirs()
        let enabledDirs = watched.filter { $0.value }.map { $0.key }

        // Load managed categories per dir from config
        var allManaged: Set<String> = ["_old"]
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let byDir = cfg["category_folders_by_dir"] as? [String: [String]] {
                for cats in byDir.values { allManaged.formUnion(cats) }
            }
            if let legacy = cfg["category_folders"] as? [String] {
                allManaged.formUnion(legacy)
            }
        }

        var parts: [String] = []
        for dirName in enabledDirs.sorted() {
            let url = home.appendingPathComponent(dirName)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                let count = contents.filter { !$0.hasPrefix(".") && !allManaged.contains($0) }.count
                if count > 0 { parts.append("\(dirName): \(count)") }
            }
        }
        fileCountItem.title = parts.isEmpty ? "📁 All tidy!" : "📁 " + parts.joined(separator: " · ")

        if let data = try? Data(contentsOf: logURL),
           let log = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ts = log["timestamp"] as? String,
           let moved = log["files_moved"] as? Int {
            let ago = formatAgo(ts)
            lastRunItem.title = "Last run: \(ago) (\(moved) moved)"
        }
    }

    func checkAutoTidy() {
        guard autoTidyItem.state == .on else { return }

        if let data = try? Data(contentsOf: logURL),
           let log = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ts = log["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: ts) ?? {
                let f2 = DateFormatter()
                f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                return f2.date(from: ts)
            }()
            if let d = date, Date().timeIntervalSince(d) < 14400 { return }
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.runCLI(args: ["--move"])
            DispatchQueue.main.async {
                self.refreshStatus()
                let summary = self.extractSummary(result)
                if summary.contains("Moved") || summary.contains("✅") {
                    self.sendNotification(title: "Sortwise — Auto", body: summary)
                }
            }
        }
    }

    func setDefaultIcon() {
        if let button = statusItem.button,
           let img = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "Sortwise") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = img.withSymbolConfiguration(config)
        }
    }

    // MARK: - Helpers

    func runCLI(args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)

        var fullArgs = args
        if aiToggleItem.state == .off && !fullArgs.contains("--no-ai") {
            fullArgs.append("--no-ai")
        }
        process.arguments = fullArgs
        process.standardOutput = pipe
        process.standardError = pipe

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func extractSummary(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let moved = lines.first(where: { $0.contains("Moved") || $0.contains("✅") }) {
            return moved
        }
        if let tidy = lines.first(where: { $0.contains("tidy") || $0.contains("empty") }) {
            return tidy
        }
        if let plan = lines.first(where: { $0.contains("files to organize") || $0.contains("DRY RUN") }) {
            return plan
        }
        return lines.last(where: { !$0.isEmpty }) ?? "Done"
    }

    func formatAgo(_ isoString: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = f.date(from: isoString) else { return isoString }
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(elapsed / 60)m ago" }
        if elapsed < 86400 { return "\(elapsed / 3600)h ago" }
        return "\(elapsed / 86400)d ago"
    }

    func loadWatchedDirs() -> [String: Bool] {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let watched = cfg["watched_dirs"] as? [String: Bool] else {
            return ["Downloads": true, "Documents": false, "Desktop": false]
        }
        return watched
    }

    func saveWatchedDir(_ dirName: String, enabled: Bool) {
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cfg = existing
        }
        var watched = (cfg["watched_dirs"] as? [String: Bool]) ?? ["Downloads": true, "Documents": false, "Desktop": false]
        watched[dirName] = enabled
        cfg["watched_dirs"] = watched
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: .prettyPrinted) {
            try? data.write(to: configURL)
        }
    }

    func loadConfigBool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let val = cfg[key] as? Bool else { return defaultValue }
        return val
    }

    func saveConfigBool(_ key: String, value: Bool) {
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cfg = existing
        }
        cfg[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: .prettyPrinted) {
            try? data.write(to: configURL)
        }
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
