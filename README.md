# Pareto Timer

A small macOS menu bar timer. One activity runs at a time; the dropdown shows
today's activities ranked longest-first with each one's share of the day and a
running cumulative percentage, so the 80/20 split is visible at a glance.

[![build](https://github.com/rsee301/pareto-timer/actions/workflows/build.yml/badge.svg)](https://github.com/rsee301/pareto-timer/actions/workflows/build.yml)

## Install

### Download (no build tools needed)

One line in Terminal downloads the latest release, installs it to
`/Applications`, and launches it:

```bash
curl -fsSL https://github.com/rsee301/pareto-timer/releases/latest/download/ParetoTimer.zip -o /tmp/ParetoTimer.zip \
  && ditto -x -k /tmp/ParetoTimer.zip /Applications && open /Applications/ParetoTimer.app
```

Or download `ParetoTimer.zip` from the
[latest release](https://github.com/rsee301/pareto-timer/releases/latest), unzip it, and
drag `ParetoTimer.app` to `/Applications`.

The app is ad-hoc signed, not notarized. A browser download is quarantined,
so macOS blocks the first launch. Fix it one of two ways:

- **System Settings > Privacy & Security**, scroll down, click **Open Anyway**.
- Or in Terminal: `xattr -dr com.apple.quarantine /Applications/ParetoTimer.app`

The `curl` line above does not trigger this.

The build is universal (Apple silicon and Intel), macOS 11 or later.

### Build from source

```bash
bash build.sh
```

That compiles the app, bundles it, installs it to `/Applications`, and launches
it. Look for the timer icon in the menu bar.

If `swiftc` is missing, run `xcode-select --install` once and try again. No
other dependencies: no Homebrew, no Python, nothing to keep updated.

- Install somewhere else: `bash build.sh ~/Applications`
- Build only, no install: `bash build.sh --no-install`

## Releases

CI (`.github/workflows/build.yml`) builds the app on every push and pull
request and keeps the zip as a workflow artifact. To publish a download, push
a version tag:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

CI builds that version and attaches `ParetoTimer.zip` to a GitHub release.

## Using it

The menu bar shows the current activity and its elapsed time, or today's total
when nothing is running.

- **Start new activity…** (⌘N): type a name, or pick one you've used before
  from the dropdown. Starting a new activity stops the current one.
- **Click any row in the ranked list** to switch straight back to that activity.
- **Stop timer** (⌘S): stops the clock without starting anything else.
- **Reset today…**: clears today's log only; earlier days are kept.
- **Open at login**: toggles autostart (macOS 13+).

### Reading the list

```
ACTIVITY                 TIME   SHARE    CUM
1. Propulsion review  1:52:10    41%     41%
2. Email                55:30    20%     61%
3. Standups             48:00    18%     79%
4. Slack                31:12    11%     90%
   ── 80% line ── 4 of 9 activities ──
5. Expense report       14:05     5%     95%
...
```

**SHARE** is that activity's percentage of the day. **CUM** is the running
total. The 80% line marks where the cumulative share crosses 80%: everything
above it is the vital few, everything below is the trivial many.

Totals cover today only and roll over at midnight on their own.

## Where the data lives

`~/Library/Application Support/ParetoTimer/entries.json`: plain JSON, one
record per tracked stretch (`activity`, `start`, `end`). **Show data file in
Finder** in the menu opens it. History is never deleted, so past days remain
available if you want to chart them later. Reinstalling or updating the app
does not touch this file.

## Notes

- It runs as a menu bar accessory, so it has no Dock icon and no window.
- A stretch shorter than one second is discarded, so mis-clicks don't show up.
- If the app crashes, the running activity is closed out at its last recorded
  second (the file is flushed every 30 seconds).

## Changing it

Everything is in `ParetoTimer.swift` (~450 lines, AppKit only). Re-run
`bash build.sh` after any edit. Some likely tweaks:

- `totals(on:now:)` in `Store`: change the window from today to this week.
- `menuNeedsUpdate`: the row format string and the `cum >= 80` cut-off.
- `refreshTitle`: what the menu bar itself displays.
