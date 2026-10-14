//
//  ParetoTimer.swift
//  A tiny macOS menu bar time tracker with a Pareto (80/20) breakdown,
//  a queue of planned tasks, and a countdown ring.
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
    var open: Bool?              // true while the timer is actively running
    var planned: TimeInterval?   // countdown length in seconds; nil counts up
}

struct QueueItem: Codable {
    var name: String
    var minutes: Int
}

final class Store {

    var entries: [Entry] = []
    var queue: [QueueItem] = []
    let fileURL: URL
    let queueURL: URL
    let folderURL: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ParetoTimer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        folderURL = base
        fileURL = base.appendingPathComponent("entries.json")
        queueURL = base.appendingPathComponent("queue.json")
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
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL) {
            entries = (try? dec.decode([Entry].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: queueURL) {
            queue = (try? dec.decode([QueueItem].self, from: data)) ?? []
        }
    }

    func save() { write(entries, to: fileURL) }

    func saveQueue() { write(queue, to: queueURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
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

func minutesText(_ minutes: Int) -> String {
    humanDuration(TimeInterval(minutes * 60))
}

// Countdown text: whole seconds left, or "+m:ss" once in overtime.
func countdownText(_ left: TimeInterval) -> String {
    left < 0 ? "+" + hms(-left) : hms(left.rounded(.up))
}

func pad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width - 1)) + "…" }
    return s + String(repeating: " ", count: width - s.count)
}

func padLeft(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

// Reads "25", "25m", "1:30", "1h", "1h30" or "1.5h" as whole minutes.
func parseMinutes(_ raw: String) -> Int? {
    var s = raw.lowercased().replacingOccurrences(of: " ", with: "")
    if s.hasSuffix("min") { s.removeLast(3) } else if s.hasSuffix("m") { s.removeLast() }
    if s.isEmpty { return nil }

    let total: Int
    if s.contains(":") {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        total = h * 60 + m
    } else if let hIdx = s.firstIndex(of: "h") {
        guard let h = Double(s[..<hIdx]) else { return nil }
        let rest = s[s.index(after: hIdx)...]
        guard let m = rest.isEmpty ? 0 : Int(rest) else { return nil }
        total = Int((h * 60).rounded()) + m
    } else {
        guard let m = Double(s) else { return nil }
        total = Int(m.rounded())
    }
    return total > 0 ? total : nil
}

// MARK: - Countdown drawing

// A ring whose arc starts at 12 o'clock and shrinks back to it as time runs out.
func drawRing(in rect: NSRect, fraction: CGFloat, lineWidth: CGFloat,
              track: NSColor, fill: NSColor) {
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2 - lineWidth / 2

    let trackPath = NSBezierPath()
    trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    trackPath.lineWidth = lineWidth
    track.setStroke()
    trackPath.stroke()

    let f = max(0, min(1, fraction))
    guard f > 0 else { return }
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                  endAngle: 90 - 360 * f, clockwise: true)
    arc.lineWidth = lineWidth
    arc.lineCapStyle = .round
    fill.setStroke()
    arc.stroke()
}

// A circle outline with a filled wedge for the time left. Small enough for
// the menu bar, where a thin ring is hard to read.
func drawPie(in rect: NSRect, fraction: CGFloat, color: NSColor) {
    let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
    outline.lineWidth = 1.4
    color.setStroke()
    outline.stroke()

    let f = max(0, min(1, fraction))
    guard f > 0 else { return }
    let inner = rect.insetBy(dx: 3, dy: 3)
    color.setFill()
    if f >= 0.999 {
        NSBezierPath(ovalIn: inner).fill()
        return
    }
    let center = NSPoint(x: inner.midX, y: inner.midY)
    let wedge = NSBezierPath()
    wedge.move(to: center)
    wedge.appendArc(withCenter: center, radius: inner.width / 2, startAngle: 90,
                    endAngle: 90 - 360 * f, clockwise: true)
    wedge.close()
    wedge.fill()
}

func pieImage(fraction: CGFloat, overtime: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        drawPie(in: rect, fraction: overtime ? 1 : fraction,
                color: overtime ? .systemRed : .black)
        return true
    }
    // Template images follow the menu bar's light or dark look; overtime stays red.
    img.isTemplate = !overtime
    return img
}

// The large countdown ring at the top of the dropdown.
final class RingView: NSView {

    var fraction: CGFloat = 1
    var overtime = false
    var timeText = ""
    var subText = ""
    var caption = ""

    override func draw(_ dirtyRect: NSRect) {
        let ringSize: CGFloat = 104
        let ringRect = NSRect(x: (bounds.width - ringSize) / 2,
                              y: bounds.height - ringSize - 10,
                              width: ringSize, height: ringSize)
        let accent: NSColor = overtime ? .systemRed : .controlAccentColor
        drawRing(in: ringRect, fraction: overtime ? 1 : fraction, lineWidth: 9,
                 track: .quaternaryLabelColor, fill: accent)

        drawCentered(timeText, centerY: ringRect.midY + 7, attrs: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: overtime ? NSColor.systemRed : NSColor.labelColor
        ])
        drawCentered(subText, centerY: ringRect.midY - 15, attrs: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        drawCentered(caption, centerY: 16, attrs: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
    }

    private func drawCentered(_ s: String, centerY: CGFloat,
                              attrs: [NSAttributedString.Key: Any]) {
        let str = NSAttributedString(string: s, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: centerY - size.height / 2))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    let store = Store()
    var statusItem: NSStatusItem!
    var ticker: Timer?
    var saveCounter = 0
    var timeUpShown = false          // the time-up alert fires once per countdown
    weak var ringView: RingView?     // live only while the menu is built
    let timerSymbol = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pareto Timer")

    var runningIndex: Int? {
        store.entries.indices.last.flatMap { store.entries[$0].open == true ? $0 : nil }
    }

    // Seconds left on the running countdown (negative in overtime); nil when counting up.
    func remaining(now: Date = Date()) -> TimeInterval? {
        guard let i = runningIndex, let planned = store.entries[i].planned else { return nil }
        return planned - now.timeIntervalSince(store.entries[i].start)
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
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
            if let left = remaining(now: now), left <= 0, !timeUpShown {
                timeUpShown = true
                DispatchQueue.main.async { [weak self] in self?.timeUp() }
            }
        }
        refreshTitle()
        updateRingView()
    }

    // MARK: status bar title

    func refreshTitle() {
        guard let button = statusItem.button else { return }
        if let i = runningIndex {
            let e = store.entries[i]
            let name = pad(e.activity, 17).trimmingCharacters(in: .whitespaces)
            if let planned = e.planned, let left = remaining() {
                button.image = pieImage(fraction: CGFloat(max(0, left) / max(planned, 1)),
                                        overtime: left < 0)
                button.title = " \(name)  \(countdownText(left))"
            } else {
                button.image = timerSymbol
                button.title = " \(name)  \(hms(Date().timeIntervalSince(e.start)))"
            }
        } else {
            button.image = timerSymbol
            let today = store.totals(on: Date(), now: Date())
            let total = today.reduce(0) { $0 + $1.seconds }
            button.title = total > 0 ? " \(humanDuration(total))" : " Idle"
        }
    }

    func updateRingView() {
        guard let v = ringView, let i = runningIndex,
              let planned = store.entries[i].planned, let left = remaining() else { return }
        v.fraction = CGFloat(max(0, left) / max(planned, 1))
        v.overtime = left < 0
        v.timeText = countdownText(left)
        v.subText = left < 0 ? "over \(humanDuration(planned))" : "of \(humanDuration(planned))"
        v.caption = store.entries[i].activity
        v.needsDisplay = true
    }

    // MARK: timer control

    func startTimer(named rawName: String, planned: TimeInterval? = nil) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        stopTimer()
        store.entries.append(Entry(activity: name, start: Date(), end: Date(), open: true,
                                   planned: planned))
        timeUpShown = false
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
        timeUpShown = false
        store.save()
        refreshTitle()
    }

    // Sets the countdown to end `seconds` from now.
    func extendCountdown(by seconds: TimeInterval) {
        guard let i = runningIndex else { return }
        store.entries[i].planned = Date().timeIntervalSince(store.entries[i].start) + seconds
        timeUpShown = false
        store.save()
        refreshTitle()
    }

    func startQueued(at index: Int) {
        guard store.queue.indices.contains(index) else { return }
        let item = store.queue.remove(at: index)
        store.saveQueue()
        startTimer(named: item.name, planned: TimeInterval(item.minutes * 60))
    }

    func timeUp() {
        guard let i = runningIndex else { return }
        let name = store.entries[i].activity
        statusItem.menu?.cancelTracking()
        NSSound(named: "Glass")?.play()
        NSApp.activate(ignoringOtherApps: true)

        let a = NSAlert()
        a.messageText = "Time is up: \(name)"
        var actions: [() -> Void] = []
        if let next = store.queue.first {
            a.informativeText = "Next in the queue: \(next.name) (\(minutesText(next.minutes)))."
            a.addButton(withTitle: "Start “\(next.name)”")
            actions.append { [weak self] in self?.startQueued(at: 0) }
        } else {
            a.informativeText = "The queue is empty."
        }
        a.addButton(withTitle: "5 More Minutes")
        actions.append { [weak self] in self?.extendCountdown(by: 300) }
        a.addButton(withTitle: "Keep Going")
        actions.append { }
        a.addButton(withTitle: "Stop")
        actions.append { [weak self] in self?.stopTimer() }

        let response = a.runModal()
        let picked = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if actions.indices.contains(picked) { actions[picked]() }
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
            if e.planned != nil {
                let v = RingView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
                v.autoresizingMask = [.width]
                ringView = v
                updateRingView()
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.view = v
                menu.addItem(item)
            } else {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = mono("▶︎ \(e.activity) — \(hms(now.timeIntervalSince(e.start)))",
                                            weight: .semibold)
                item.isEnabled = false
                menu.addItem(item)
            }
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

        // --- queue --------------------------------------------------------
        if store.queue.isEmpty {
            menu.addItem(header("QUEUE · empty"))
        } else {
            let planned = store.queue.reduce(0) { $0 + $1.minutes }
            menu.addItem(header(
                "QUEUE · \(store.queue.count) left · \(minutesText(planned)) planned"))
            for (idx, q) in store.queue.enumerated() {
                let item = NSMenuItem(title: q.name, action: nil, keyEquivalent: "")
                item.attributedTitle = mono(pad("\(idx + 1). \(q.name)", 37)
                                            + padLeft(minutesText(q.minutes), 7))
                let sub = NSMenu()
                sub.addItem(actionItem("Start now", #selector(startQueuedItem(_:)), tag: idx))
                if idx > 0 {
                    sub.addItem(actionItem("Move to top", #selector(moveQueuedToTop(_:)), tag: idx))
                }
                sub.addItem(actionItem("Remove", #selector(removeQueued(_:)), tag: idx))
                item.submenu = sub
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // --- controls -----------------------------------------------------
        let newItem = NSMenuItem(title: "Start new activity…",
                                 action: #selector(promptNewActivity), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)

        if let next = store.queue.first {
            menu.addItem(actionItem("Start next: \(next.name) (\(minutesText(next.minutes)))",
                                    #selector(startNextPressed), key: "\r"))
        }
        menu.addItem(actionItem("Add to queue…", #selector(promptAddToQueue), key: "a"))
        if !store.queue.isEmpty {
            menu.addItem(actionItem("Clear queue…", #selector(clearQueue)))
        }

        if remaining() != nil {
            menu.addItem(actionItem("Add 5 minutes", #selector(addFiveMinutes)))
        }

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

    func actionItem(_ title: String, _ action: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        return item
    }

    // A name box (with recent names) above a minutes box, for an NSAlert.
    func taskFields(name: String, minutes: String,
                    placeholder: String) -> (NSView, NSComboBox, NSTextField) {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))

        let nameField = NSComboBox(frame: NSRect(x: 0, y: 34, width: 260, height: 26))
        nameField.addItems(withObjectValues: store.recentNames(limit: 12))
        nameField.completes = true
        nameField.placeholderString = "Activity"
        nameField.stringValue = name

        let minutesField = NSTextField(frame: NSRect(x: 0, y: 2, width: 90, height: 24))
        minutesField.placeholderString = placeholder
        minutesField.stringValue = minutes

        let label = NSTextField(labelWithString: "minutes")
        label.frame = NSRect(x: 98, y: 5, width: 100, height: 17)
        label.textColor = .secondaryLabelColor

        view.addSubview(nameField)
        view.addSubview(minutesField)
        view.addSubview(label)
        nameField.nextKeyView = minutesField
        return (view, nameField, minutesField)
    }

    // MARK: actions

    @objc func resumeActivity(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        startTimer(named: name)
    }

    @objc func stopPressed() { stopTimer() }

    @objc func startNextPressed() { startQueued(at: 0) }

    @objc func addFiveMinutes() {
        guard let left = remaining() else { return }
        extendCountdown(by: max(0, left) + 300)
    }

    @objc func startQueuedItem(_ sender: NSMenuItem) { startQueued(at: sender.tag) }

    @objc func moveQueuedToTop(_ sender: NSMenuItem) {
        guard store.queue.indices.contains(sender.tag) else { return }
        store.queue.insert(store.queue.remove(at: sender.tag), at: 0)
        store.saveQueue()
    }

    @objc func removeQueued(_ sender: NSMenuItem) {
        guard store.queue.indices.contains(sender.tag) else { return }
        store.queue.remove(at: sender.tag)
        store.saveQueue()
    }

    @objc func clearQueue() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Clear the queue?"
        a.informativeText = "All \(store.queue.count) planned tasks are removed. Tracked time is kept."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.queue.removeAll()
        store.saveQueue()
    }

    @objc func promptNewActivity() {
        NSApp.activate(ignoringOtherApps: true)
        var note = "What are you working on? Add minutes for a countdown, or leave them blank to count up."
        var name = "", minutes = ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Start tracking"
            alert.informativeText = note
            alert.addButton(withTitle: "Start")
            alert.addButton(withTitle: "Cancel")
            let (view, nameField, minutesField) = taskFields(name: name, minutes: minutes,
                                                             placeholder: "optional")
            alert.accessoryView = view
            alert.window.initialFirstResponder = nameField
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            name = nameField.stringValue
            minutes = minutesField.stringValue.trimmingCharacters(in: .whitespaces)
            if minutes.isEmpty {
                startTimer(named: name)
                return
            }
            if let m = parseMinutes(minutes) {
                startTimer(named: name, planned: TimeInterval(m * 60))
                return
            }
            NSSound.beep()
            note = "“\(minutes)” is not a time. Use 25, 1:30 or 1h30, or leave it blank."
        }
    }

    @objc func promptAddToQueue() {
        NSApp.activate(ignoringOtherApps: true)
        var note = "Plan a task for today. Time: 25, 1:30 or 1h30 (blank is 25 minutes)."
        var name = "", minutes = ""
        while true {
            let alert = NSAlert()
            alert.messageText = "Add to queue"
            alert.informativeText = note
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Add Another")
            alert.addButton(withTitle: "Cancel")
            let (view, nameField, minutesField) = taskFields(name: name, minutes: minutes,
                                                             placeholder: "25")
            alert.accessoryView = view
            alert.window.initialFirstResponder = nameField
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }

            name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            minutes = minutesField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let m = minutes.isEmpty ? 25 : parseMinutes(minutes) else {
                NSSound.beep()
                note = "Enter a name and a time like 25, 1:30 or 1h30."
                continue
            }
            store.queue.append(QueueItem(name: name, minutes: m))
            store.saveQueue()
            if response == .alertFirstButtonReturn { return }
            note = "Added “\(name)” (\(minutesText(m))). Add the next one."
            name = ""
            minutes = ""
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
