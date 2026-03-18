# MacGuard

A production-quality macOS system utility that combines Activity Monitor, App Uninstaller, Login Items Manager, Startup Impact Scorer, and AI-powered Disk Analyzer into a single menu bar app.

Built entirely in Swift using SwiftUI, targeting macOS 13+. Direct distribution (no App Store), no Dock icon, lives in the menu bar.

---

## Screenshots

> Add screenshots here after building

---

## Features

### 🖥 Activity Monitor
Real-time process monitoring using two-sample delta CPU measurement — the same method macOS Activity Monitor uses internally.

- CPU% calculated from cumulative `ps time=` ticks delta between polls (not lifetime average)
- RAM, thread count per process
- Sparkline history charts (30 samples)
- Sort by CPU, RAM, or Threads
- Hover-reveal Quit / Force Kill buttons
- Auto-kill threshold — automatically terminates processes exceeding a CPU%
- 2s foreground polling / 30s background polling
- Total CPU, RAM, process count, thread count summary bar

### 🗑 App Uninstaller
Deep app removal that handles every macOS edge case.

**What it finds:**
- App bundle + all related files via Spotlight (`mdfind`), `pkgutil` receipts, and directory scan
- LaunchAgents and LaunchDaemons
- Privileged helper tools (`/Library/PrivilegedHelperTools`)
- App containers, caches, logs, preferences, saved state
- Crash and diagnostic reports
- App-installed fonts
- Temp caches in `/private/var/folders`

**How it deletes safely:**
- Phase 1: UTI deregistration via `lsregister -u` (before bundle is deleted)
- Phase 2: Kill all processes by bundle ID + app name
- Phase 3: `launchctl bootout/unload/remove` before deleting plists (prevents launchd re-spawn)
- Phase 4: Per-file `lsof` batch kill, `chflags nouchg`, `chmod -RN` (strip ACLs), `xattr -cr`, then `rm`
- Phase 5: `pkgutil --forget`, `tccutil reset All`, Launch Services DB rebuild

**Edge cases handled:**

| Scenario | Fix |
|---|---|
| File handle open | `lsof` batch kill before delete |
| launchd re-spawns daemon | `launchctl bootout/unload/remove` before plist deletion |
| Immutable flag (`uchg`) | `chflags -R nouchg` |
| Quarantine xattr | `xattr -cr` |
| ACL entries | `chmod -RN` |
| App still running | `pgrep` kill by bundle ID and app name |
| SIP-protected paths | Detected, shown with 🛡 badge, excluded |
| Vendor uninstaller exists | Banner with "Run Official Uninstaller" |
| Gatekeeper App Translocation | Resolved via `realpath()` syscall |
| Read-only volume (DMG) | Detected via `statfs(MNT_RDONLY)` |
| iCloud evicted files | Detected via `ubiquitousItemDownloadingStatusKey` |
| Hard-linked files | `nlink` check — `spaceSaved = 0` for multi-linked files |
| Shared libraries | `pkgutil --file-info` cross-reference (cached) |
| TCC privacy permissions | `tccutil reset All <bundleID>` |
| Symlinks | `lstat` detection → `rm -f` (not `-rf`) |

### 🔐 Login Items Manager
Full visibility and control over everything that runs at login.

- Parses `sfltool dumpbtm` (requires Full Disk Access for complete results)
- Falls back to directory scan of `/Library/LaunchDaemons`, `/Library/LaunchAgents`, `~/Library/LaunchAgents`
- Shows type (LaunchDaemon / LaunchAgent / Login Item / Background Item)
- Enable/disable via `launchctl bootstrap/bootout`
- Remove plists directly
- FDA banner with "Relaunch Now" button (menu bar apps don't quit on window close)
- Loads only once per session — guarded against SwiftUI's `onAppear` firing on every tab switch

### ⚡ Startup Impact Scorer
Scores every login item by how much it slows your Mac at login.

**Two-phase scoring:**

*Heuristic (instant, from plist keys):*
- `KeepAlive: true` → +25 pts (always-running, biggest factor)
- `RunAtLoad` → +10 pts
- `StartInterval < 60s` → +15 pts (frequent wakeups)
- `Sockets` → +12 pts (network listener)
- `MachServices` → +8 pts (IPC endpoint)
- Binary size → up to +12 pts (disk I/O at launch)
- Type: LaunchDaemon → +35 pts base

*Live (when process is running):*
- Real-time CPU and RAM from `ProcessMonitor`
- Blended with heuristic score: 60% structural + 40% live behaviour
- Live CPU/RAM pills shown on running processes

**Score levels:** 🟢 Low (0–25) · 🟡 Medium (26–50) · 🟠 High (51–74) · 🔴 Critical (75–100)

### 💽 Disk Analyzer
Two-pass folder scanner with live results.

- **Pass 1:** Directory listing publishes all items immediately — files with real sizes, folders as pending placeholders
- **Pass 2:** `du -skx` runs concurrently (4 threads) per folder, sizes fill in live
- Animated shimmer on pending items, progress bar fills as folders complete
- Horizontal bar chart (top 12 items + "Other" overflow bar)
- Right-click → Reveal in Finder
- Drill-down into folders with breadcrumb navigation (back button, truncation for deep paths, folder icons)
- Volume usage bar showing this folder vs total disk
- Quick-scan shortcuts: Home, Downloads, Documents, Desktop, /Applications, ~/Library

### 🧹 Smart Cleanup (AI-powered)
Two-phase cleanup engine: rule-based classification + optional Claude Haiku review.

**Phase 1 — Rule engine (instant):**

Classifies items by path convention, extension, size, and last-accessed date:

| Path pattern | Category | Safety |
|---|---|---|
| `/Library/Caches/` | Cache | ✅ Safe |
| `/Library/Logs/` | Log | ✅ Safe |
| `node_modules/`, `.gradle/caches/` | Cache | ✅ Safe |
| `/tmp/`, `*.tmp` | Temporary | ✅ Safe |
| `~/Downloads/` >10MB | Download | ⚠️ Caution |
| Large `.mov/.mp4/.dmg` >100MB | Large Media | ⚠️ Caution |
| `/Application Support/` >50MB | App Data | 🔴 Review |

**Confidence scoring (0–100)** per item from three signals:
- Path certainty: `/Library/Caches/` = 50 pts, App Support = 10 pts
- Last-accessed recency: 2+ years = +30 pts, this week = +0 pts
- Filename risk: "backup", "passport", "invoice" → −20 pts

**Phase 2 — Claude Haiku review (optional, ~1–2s):**

Only ambiguous items are sent (80–90% cost reduction vs sending all items):
1. Unknown category items (rule engine gave up)
2. App containers (`/Containers/`) — Haiku judges active vs abandoned
3. Large uncertain items >50MB
4. Ambiguous filenames on non-safe items (installers, backups, old projects)

Haiku returns overrides with improved classifications. AI-enhanced items marked with ✦.

**Staging board UX:**
- Safe items auto-staged on open
- Active-process containers confidence-capped at 45 (never auto-stage)
- Move to Trash button (always recoverable)
- Permanent delete button — only for items with confidence ≥ 90%, requires typing "DELETE"
- Retry logic: strips `chflags nouchg` + `xattr -cr` before second attempt
- Kills container-owning process before trashing (handles permission errors)

---

## Architecture

```
MacGuard/
├── main.swift                  # AppDelegate, NSStatusBar setup, window management
├── ContentView.swift           # Sidebar navigation (AppSection enum, 5 tabs)
│
├── Activity Monitor
│   ├── ProcessMonitor.swift    # ps-based polling, two-sample delta CPU, sparkline history
│   └── ProcessMonitorView.swift
│
├── Uninstaller
│   ├── AppUninstaller.swift    # 5-phase deletion engine, 789 lines
│   └── UninstallerView.swift
│
├── Login Items
│   ├── LoginItemsManager.swift # sfltool dumpbtm parser + directory scan fallback
│   ├── LoginItemsView.swift
│   └── LoginItemManager.swift  # MacGuard's own login item (SMAppService.mainApp)
│
├── Startup Impact
│   ├── StartupScorer.swift     # Heuristic + live scoring engine
│   └── StartupImpactView.swift
│
├── Disk Analyzer + Smart Cleanup
│   ├── Diskanalyzer.swift      # Two-pass scanner, du subprocess, concurrent sizing
│   ├── Diskanalyzerview.swift  # Chart, list, breadcrumbs, cleanup sheet trigger
│   ├── CleanupEngine.swift     # Rule-based classifier, confidence scoring, trash/delete
│   ├── CleanupView.swift       # Staging board UI, permanent delete confirmation
│   └── CleanupAI.swift         # Haiku integration, precision filter, merge logic
│
├── Menu Bar
│   ├── MenuBarController.swift # NSStatusItem, NSPopover (.applicationDefined behavior)
│   └── MenuBarView.swift       # Popover UI, stats, process rows, settings
│
└── Shared
    ├── SettingsManager.swift   # UserDefaults-backed singleton
    ├── NotificationManager.swift
    └── SparklineView.swift     # Path-based sparkline with gradient fill
```

---

## Technical Decisions

### CPU Measurement
`ps -axo pcpu=` gives a **lifetime average** since process start — useless for real-time monitoring. MacGuard uses `ps -axo pid=,time=,rss=,nlwp=,user=,comm=` to get cumulative CPU seconds, stores them per PID, then computes:

```
cpu% = (delta_cpu_seconds / elapsed_wall_seconds / cpu_count) × 100
```

This matches Activity Monitor's values. First poll always shows 0% (no previous sample) — accurate values appear from the second poll (2 seconds later).

### Privilege Escalation
`NSAppleScript` + `do shell script ... with administrator privileges`. **Not** migrated to `SMJobBless` (deprecated) or `SMAppService` (requires System Settings approval UX). Migrate only when:
- Adding App Sandbox entitlement
- Submitting to App Store
- Wanting a persistent root helper (avoids re-prompting per uninstall)

### Popover Anchoring
`NSPopover.behavior = .applicationDefined`. After `popover.show(relativeTo:of:preferredEdge:)`, **never call `makeKey()`** on the popover's window — it detaches the popover from its anchor and floats it to screen centre.

### Translocation Resolution
`SecTranslocateCreateOriginalPathForURL` is explicitly unsupported for third-party use. MacGuard uses `realpath()` syscall which resolves the bind-mount macOS uses for Gatekeeper App Translocation.

### Keychain Checking
Every approach — `dump-keychain`, `find-generic-password`, `SecItemCopyMatching` — can trigger macOS auth prompts. No CLI or framework path reads keychain entries without risking a prompt. The keychain advisory was removed entirely.

### Login Items `onAppear` Guard
SwiftUI's `onAppear` fires on every sidebar selection change. Login Items loads only once:
```swift
.onAppear {
    if manager.items.isEmpty && !manager.isLoading { manager.refresh() }
}
```

### sfltool + Full Disk Access
`sfltool dumpbtm` works silently with FDA, returns empty without it. The FDA banner has a "Relaunch Now" button that calls `NSWorkspace.openApplication` + `NSApp.terminate` — the only reliable way to get FDA to activate for a menu bar app that never fully quits.

### DiskAnalyzer Cancellation
Uses `private var scanGeneration: Int` incremented on each new scan. Every async operation checks `scanGeneration == gen` before publishing. `DispatchWorkItem` cancellation was abandoned — inverted guard logic caused scans to exit immediately.

---

## Requirements

- macOS 13.0+
- Xcode 15+
- Swift 5.9+
- Anthropic API key (optional — required only for Smart Cleanup AI enhancement)

---

## Building

```bash
# Clone
git clone https://github.com/yourusername/MacGuard.git
cd MacGuard

# Build release
swift build -c release

# Install
cp .build/release/MacGuard /Applications/MacGuard.app/Contents/MacOS/MacGuard
xattr -cr /Applications/MacGuard.app
codesign --force --deep --sign - /Applications/MacGuard.app

# Launch
open /Applications/MacGuard.app
```

### API Key Setup (Smart Cleanup AI)

Open `Diskanalyzerview.swift` and replace the placeholder:

```swift
cleanupEngine.analyse(
    rootURL:  analyzer.rootURL ?? ...,
    allItems: analyzer.items,
    apiKey:   "sk-ant-YOUR-KEY-HERE"   // ← replace this
)
```

For production, load from Keychain instead of hardcoding:
```swift
// Store once
try? KeychainItem(service: "MacGuard", account: "anthropic-key").saveItem(apiKey)

// Load
let apiKey = try? KeychainItem(service: "MacGuard", account: "anthropic-key").readItem()
```

---

## Known Limitations

| Area | Limitation |
|---|---|
| Keychain entries | No CLI/API path reads keychain without triggering auth prompts — advisory removed |
| SMLoginItem deregistration | Cannot unregister another app's `SMAppService` entries without `sfltool resetbtm` (clears all apps) |
| System Extensions | Require SIP disabled + Recovery Mode — flagged, not automated |
| Kernel Extensions | `kextunload` attempted but full removal requires reboot |
| Network Extensions | Require manual removal in System Settings |
| APFS snapshots | Deleted files remain recoverable until snapshot expires — user warned |
| Local Items keychain | Not accessible via any API without user-facing auth prompt |
| `NSAppleScript` escalation | Not App Sandbox-safe — see Technical Decisions above |

---

## Contributing

### Project Structure Notes for Contributors

**Adding a new Uninstaller scan layer:**
`AppUninstaller.findRelatedFiles()` runs four layers (Spotlight, pkgutil, directory scan, var/folders). Add a Layer 5 by appending to the `found` array before the final sort. Use the existing `add(_:source:)` closure pattern.

**Adding a new Startup Impact heuristic:**
`StartupScorer.heuristicScore()` is a simple additive scoring function. Add new plist key checks in the `guard let plistURL` block. Score contributions should sum to ≤ 100 across all signals.

**Adding a new Cleanup category:**
1. Add case to `CleanupCategory` enum in `CleanupEngine.swift`
2. Add detection rule in `classify()` using `makeItem(category:safety:reason:)`
3. Add color in `CleanupView.colorFor()` and `DiskAnalyzerView`

**Adding a new AI filter criterion:**
The precision filter in `CleanupEngine.analyse()` has four numbered criteria. Add a fifth `if` block returning `true` for items that need AI review. Keep it conservative — false positives cost tokens, false negatives just mean the rule engine handles it.

**Replacing NSAppleScript with SMAppService:**
See comments marked `// PRIVILEGE ESCALATION NOTE:` in `AppUninstaller.swift`. The XPC protocol is designed and ready in concept — three files needed: `MacGuardHelperProtocol.swift`, `MacGuardHelper/main.swift`, `MacGuard/PrivilegedHelper.swift`.

### Pull Request Guidelines

- Read the file you're changing completely before editing
- Surgical patches over full rewrites
- Every edge case listed in the Uninstaller table should remain covered
- Test on both Intel and Apple Silicon if possible
- `swift build -c release` must pass with zero warnings

---

## License

MIT License — see LICENSE file.

---

## Acknowledgements

Built with Swift, SwiftUI, and AppKit. AI cleanup enhancement powered by [Claude Haiku](https://anthropic.com) (Anthropic). No third-party dependencies.
