//
//  ParetoTimer.swift
//  A tiny macOS menu bar time tracker with a Pareto (80/20) breakdown.
//
//  Build:  ./build.sh
//

import Cocoa
import ServiceManagement

// MARK: - Model

struct Entry: Codable {
    var activity: String
    var start: Date
    var end: Date?
    var open: Bool?          // true while the timer is actively running
}

final class Store {

    var entries: [Entry] = []
    let fileURL: URL
    let folderURL: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ParetoTimer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        folderURL = base
        fileURL = base.appendingPathComponent("entries.json")
        load()
        // Recover from a crash: anything still marked open keeps its last
        // recorded end time and is closed out.
        var changed = false
        for i in entries.indices where entries[i].open == true {
            entries[i].open = false
            if entries[i].end == nil { entries[i].end = entries[i].start }
            changed = true
        }
        if changed { save() }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        entries = (try? dec.decode([Entry].self, from: data)) ?? []
    }

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // Seconds per activity for a given day, biggest first.
    func totals(on day: Date, now: Date) -> [(name: String, seconds: TimeInterval)] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = min(cal.date(byAdding: .day, value: 1, to: dayStart) ?? day, now)
        var dict: [String: TimeInterval] = [:]
        for e in entries {
            let s = max(e.start, dayStart)
            let t = min(e.end ?? now, dayEnd)
            if t > s { dict[e.activity, default: 0] += t.timeIntervalSince(s) }
        }
        return dict.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map { (name: $0.key, seconds: $0.value) }
    }

    // Distinct activity names, most recently used first.
    func recentNames(limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in entries.reversed() {
            if !seen.contains(e.activity) {
                seen.insert(e.activity)
                out.append(e.activity)
                if out.count >= limit { break }
            }
        }
        return out
    }
}

// MARK: - Formatting helpers

func hms(_ t: TimeInterval) -> String {
    let total = max(0, Int(t.rounded()))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}

func humanDuration(_ t: TimeInterval) -> String {
    let total = max(0, Int(t.rounded()))
    let h = total / 3600, m = (total % 3600) / 60
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    if m > 0 { return "\(m)m" }
    return "\(total)s"
}

func pad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width - 1)) + "…" }
    return s + String(repeating: " ", count: width - s.count)
}

func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    let store = Store()
    var statusItem: NSStatusItem!
    var ticker: Timer?
    var saveCounter = 0

    var runningIndex: Int? {
        store.entries.indices.last.flatMap { store.entries[$0].open == true ? $0 : nil }
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pareto Timer")
            }
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        refreshTitle()

        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopTimer()
        store.save()
    }

    @objc func tick() {
        let now = Date()
        if let i = runningIndex {
            store.entries[i].end = now
            saveCounter += 1
            if saveCounter % 30 == 0 { store.save() }
        }
        refreshTitle()
    }

    // MARK: status bar title

    func refreshTitle() {
        guard let button = statusItem.button else { return }
        if let i = runningIndex {
            let e = store.entries[i]
            let elapsed = Date().timeIntervalSince(e.start)
            button.title = " \(pad(e.activity, 17).trimmingCharacters(in: .whitespaces))  \(hms(elapsed))"
        } else {
            let today = store.totals(on: Date(), now: Date())
            let total = today.reduce(0) { $0 + $1.seconds }
            button.title = total > 0 ? " \(humanDuration(total))" : " Idle"
        }
    }

    // MARK: timer control

    func startTimer(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        stopTimer()
        store.entries.append(Entry(activity: name, start: Date(), end: Date(), open: true))
        store.save()
        refreshTitle()
    }

    func stopTimer() {
        guard let i = runningIndex else { return }
        store.entries[i].end = Date()
        store.entries[i].open = false
        // Drop entries shorter than a second so mis-clicks don't pollute the chart.
        if let end = store.entries[i].end,
           end.timeIntervalSince(store.entries[i].start) < 1 {
            store.entries.remove(at: i)
        }
        store.save()
        refreshTitle()
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let rows = store.totals(on: now, now: now)
        let total = rows.reduce(0) { $0 + $1.seconds }

        // --- header -------------------------------------------------------
        let df = DateFormatter()
        df.dateFormat = "EEEE, d MMM"
        menu.addItem(header("Today · \(df.string(from: now))"))

        if let i = runningIndex {
            let e = store.entries[i]
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = mono("▶︎ \(e.activity) — \(hms(now.timeIntervalSince(e.start)))",
                                        weight: .semibold)
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // --- pareto list --------------------------------------------------
        if rows.isEmpty {
            menu.addItem(disabled("No time logged yet today"))
        } else {
            menu.addItem(header(
                pad("ACTIVITY", 20) + padLeft("TIME", 9) + padLeft("SHARE", 8) + padLeft("CUM", 7)))

            var cumulative: TimeInterval = 0
            var drewCut = false
            for (idx, row) in rows.enumerated() {
                cumulative += row.seconds
                let share = total > 0 ? row.seconds / total * 100 : 0
                let cum = total > 0 ? cumulative / total * 100 : 0

                let line = pad("\(idx + 1). \(row.name)", 20)
                    + padLeft(hms(row.seconds), 9)
                    + padLeft(String(format: "%.0f%%", share), 8)
                    + padLeft(String(format: "%.0f%%", cum), 7)

                let item = NSMenuItem(title: row.name, action: #selector(resumeActivity(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = row.name
                item.attributedTitle = mono(line, weight: idx < 3 ? .semibold : .regular)
                item.toolTip = "Start tracking “\(row.name)”"
                menu.addItem(item)

                if !drewCut && cum >= 80 && idx < rows.count - 1 {
                    drewCut = true
                    let cut = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    cut.attributedTitle = mono(
                        "   ── 80% line ── \(idx + 1) of \(rows.count) activities ──",
                        size: 10)
                    cut.isEnabled = false
                    menu.addItem(cut)
                }
            }

            menu.addItem(.separator())
            let sum = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            sum.attributedTitle = mono(pad("TOTAL", 20) + padLeft(hms(total), 9), weight: .semibold)
            sum.isEnabled = false
            menu.addItem(sum)
        }

        menu.addItem(.separator())

        // --- controls -----------------------------------------------------
        let newItem = NSMenuItem(title: "Start new activity…",
                                 action: #selector(promptNewActivity), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)

        let stopItem = NSMenuItem(title: "Stop timer", action: #selector(stopPressed),
                                  keyEquivalent: "s")
        stopItem.target = self
        stopItem.isEnabled = runningIndex != nil
        menu.addItem(stopItem)

        let recents = store.recentNames().filter { name in
            !rows.contains { $0.name == name }
        }
        if !recents.isEmpty {
            let sub = NSMenu()
            for name in recents {
                let it = NSMenuItem(title: name, action: #selector(resumeActivity(_:)),
                                    keyEquivalent: "")
                it.target = self
                it.representedObject = name
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: "Earlier activities", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin),
                               keyEquivalent: "")
        login.target = self
        if #available(macOS 13.0, *) {
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            login.isEnabled = false
        }
        menu.addItem(login)

        let reveal = NSMenuItem(title: "Show data file in Finder", action: #selector(revealData),
                                keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let reset = NSMenuItem(title: "Reset today…", action: #selector(resetToday),
                               keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Pareto Timer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: menu item builders

    func mono(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        ])
    }

    func header(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        item.isEnabled = false
        return item
    }

    func disabled(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: actions

    @objc func resumeActivity(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        startTimer(named: name)
    }

    @objc func stopPressed() { stopTimer() }

    @objc func promptNewActivity() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Start tracking"
        alert.informativeText = "What are you working on?"
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        field.addItems(withObjectValues: store.recentNames(limit: 12))
        field.completes = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            startTimer(named: field.stringValue)
        }
    }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn’t change the login setting"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    @objc func resetToday() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Clear today’s log?"
        a.informativeText = "Today’s tracked time is deleted. Earlier days are kept."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }

        stopTimer()
        let dayStart = Calendar.current.startOfDay(for: Date())
        var kept: [Entry] = []
        for entry in store.entries {
            var e = entry
            let end = e.end ?? Date()
            if end <= dayStart {
                kept.append(e)
            } else if e.start < dayStart {
                e.end = dayStart          // truncate an entry that spanned midnight
                e.open = false
                kept.append(e)
            }
            // entries fully inside today are dropped
        }
        store.entries = kept
        store.save()
        refreshTitle()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
