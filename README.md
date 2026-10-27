# Mac Cleaner

**See what's filling your Mac's disk, and clear it safely.**

A native macOS app that combines three tools:

- **Smart cleanup**: finds caches, developer junk, old downloads, duplicates and more, and pre-selects what's safe to remove.
- **Disk Explorer**: a WizTree-style map of your whole disk, so you can see exactly where the space went.
- **App uninstaller**: shows every installed app by size and when you last opened it, and removes it together with the files
  it leaves behind in `~/Library`.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Vibe coded with Claude Opus 5.5](https://img.shields.io/badge/vibe_coded-Claude_Opus_5.5-ff69b4)

> [!WARNING]
> **This is vibe-coded software that deletes files.** It was written by an AI model, Claude Opus 5.5, with a person
> steering. It moves things to the Trash rather than deleting them outright, and it has guard rails, but it hasn't had a
> line-by-line human review or wide testing. **Back up your Mac first**, check what's selected before you clean, and read the
> [vibe-coded disclaimer](#vibe-coded-disclaimer).

![Overview](docs/screenshots/overview.png)

---

## Features

### Overview & Smart Scan

One button scans every category at once. The disk bar shows how much of your used space can be freed, and **Clean Selected**
removes everything that's ticked, with a confirmation first. While a scan runs you see live progress (files checked, current
folder), and you can stop it at any time.

### Cleanup categories

| Category | What it finds | Pre-selected as safe |
| --- | --- | --- |
| **App Caches & Logs** | Per-app folders in `~/Library/Caches` and `~/Library/Logs`, shown with real app names | Yes, except macOS's own caches |
| **Developer Junk** | Xcode DerivedData, device support files, simulator caches, Homebrew, npm, Yarn, pnpm, pip, CocoaPods, Cargo, Gradle and Go caches, Docker images and build cache, unavailable simulators, `node_modules` | Caches yes. `node_modules` only if untouched for 30+ days. Docker and simulators never |
| **Backups & Mail** | iPhone/iPad backups, downloaded iOS updates, Mail attachments you've opened | iOS updates and Mail attachments yes, backups never |
| **Old Downloads** | Items in `~/Downloads` older than an age you choose | Installers and archives (`.dmg`, `.pkg`, `.zip`, …) |
| **Large Files** | Files over a size you choose, with when you last opened them | Never |
| **Duplicates** | Byte-for-byte identical files (size → first 64 KB → full SHA-256), keeping the oldest copy | Never (one click selects the extra copies) |
| **Trash** | What's already in the Trash, the only place emptying actually frees space | Never |

![App caches](docs/screenshots/app-caches.png)

### Disk Explorer (WizTree-style)

Pick **Macintosh HD**, your home folder, or any folder and scan it. It's fast: `/Applications` (265k files) takes about 1–2
seconds, and `/System` (470k files and folders) about 4.

- **Storage bar** showing how much of the disk the scanned folder takes, what's selected, and what's free
- **Folder tree** sorted biggest-first, with a "% of parent" bar on every row
- **Largest Files**: the 1,000 biggest files anywhere on the disk, in one list
- **File Types**: total size and count per extension
- **Treemap**: every block's area is the space it takes, colored by type (images, video, apps & code, music, documents,
  data & AI models, archives & disk images, other).
  - Double-click a block to zoom in. Double-clicking a "more items" block zooms straight into the folder holding them.
  - Click a legend entry or a file type to highlight just those files.
  - Hover any block for its name, size and path.
- **Multi-select**: ⌘/⇧-click in the lists or ⌘-click on the map, then **Show in Finder** or **Move to Trash** all at once

![Disk Explorer](docs/screenshots/disk-explorer.png)

![Multi-select](docs/screenshots/multi-select.png)

It also comes in dark mode:

![Treemap in dark mode, video files highlighted](docs/screenshots/treemap-dark.png)

### Applications

Every app in `/Applications` and `~/Applications`, with:

- **Real size**: the app plus the data it keeps in `~/Library`, e.g. "1.6 GB (+1.17 GB data)"
- **When you last opened it**: sort by it, or tick **Not opened in 6 months**
- **Its leftover files**, each with a checkbox: app data, caches, settings, saved windows, web data, containers and background
  helpers
- **Uninstall**: moves the app and the ticked leftovers to the Trash, quitting the app first if it's open. Select several apps
  to uninstall them together.

Some apps get extra care:

- **App Store and other system-owned apps** go through Finder, which asks for your password the way it does when you drag
  them to the Trash yourself.
- **Built-in macOS apps** (and Mac Cleaner itself) are protected.
- **Steam shortcuts** are recognized as just launchers. Uninstalling one never touches the game's save files.

![Applications](docs/screenshots/applications.png)

---

## Install

### Download

1. Get the latest **`MacCleaner-x.y.z.dmg`** from [Releases](https://github.com/EvanMeyer36/mac-cleaner/releases/latest).
   It's a universal app that runs on Apple Silicon and Intel Macs with macOS 14 or later.
2. Open the disk image and drag **Mac Cleaner** into **Applications**.
3. **The first time you open it**, macOS will say it can't verify the app. That's because it isn't notarized (notarization
   needs a paid Apple Developer account). To open it anyway:
   1. Try to open it once, then click **Done**.
   2. Go to **System Settings → Privacy & Security**, scroll down to *"Mac Cleaner was blocked…"*, click **Open Anyway**, and
      confirm.

   Or, from Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Mac Cleaner.app"
   ```

   You only need to do this once.

### Build from source

It takes about a minute, and you don't need full Xcode.

**You'll need:**

- macOS 14 Sonoma or later
- Apple's Command Line Tools: `xcode-select --install`

```bash
git clone https://github.com/EvanMeyer36/mac-cleaner.git
cd mac-cleaner/macos
./scripts/build-app.sh --install
```

This builds **Mac Cleaner.app** and copies it to `/Applications`. Open it from Spotlight (⌘ Space → "Mac Cleaner").

- Without `--install`, the app is only built into `build/`.
- For quick development runs, `swift run` works too.
- `./scripts/release.sh` (run from `macos/`) builds the universal `.dmg` and `.zip` that go on the Releases page.

### Permissions

macOS will ask the first time Mac Cleaner looks in Desktop, Documents or Downloads. Some places need **Full Disk Access**
(System Settings → Privacy & Security → Full Disk Access):

- the Trash
- iPhone backups
- other apps' data

Whenever something was blocked, the app shows a button that takes you straight to the right settings page. In the Disk
Explorer, space it couldn't read shows up as one hatched "System data" block, so the map still adds up to your real disk usage.

The app is signed ad-hoc (built on your own Mac, not notarized), so macOS may ask for these permissions again after you rebuild it.

---

## Safety

Deleting the wrong thing is the worst thing a cleaner can do, so the app is cautious by default:

- **Scanning never changes anything.** Nothing is removed until you confirm, and the confirmation lists what's about to go.
- **Almost everything goes to the Trash**, so you can put it back. Only two things are permanent, and both are labelled
  **Permanent** and called out before you confirm:
  - emptying the Trash itself
  - Docker and simulator cleanup, which the tools themselves do (`docker image prune`, `xcrun simctl delete unavailable`)
- **Only "safe" items are pre-selected**: things apps rebuild on their own.
- **Some things are never removed**:
  - pieces of apps or media libraries such as Photos, Music, iMovie and Final Cut. Deleting a file like `Photos.sqlite-wal`
    from inside the Photos library can corrupt it.
  - standard folders like Documents or Library
  - anything outside your home folder and `/Applications`
- **Duplicates that wouldn't free anything** (APFS clones and hard links) are left out.
- **Uninstalling only takes an app's own files.** Leftovers are matched by the app's exact bundle ID, so one app's uninstall
  never takes another app's files or a shared suite container (like Microsoft Office's). A few folders are matched by the
  app's name instead; those are labelled "matched by app name", and you can untick any leftover to keep it.
- **The file-by-file searches skip `~/Library`, app bundles and `node_modules`.** Those are covered by the targeted
  categories instead.

---

## How it works

### Disk Explorer scanner

`macos/Sources/MacCleaner/Explorer/DiskTreeScanner.swift` reads directories with
[`getattrlistbulk(2)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getattrlistbulk.2.html).
Each call returns the names, types and allocated sizes of many entries at once, and folders are spread across all CPU cores.

- Hard links are counted once, so totals match `du`.
- Files under 256 KB are grouped per folder, which keeps memory bounded on disks with millions of files.
- On the startup disk it skips the firmlinked Data volume (already reached through `/Users` and friends), other volumes and
  cloud-provider folders.

### Treemap

`TreemapLayout.swift` uses the squarified algorithm (Bruls, Huizing & van Wijk) and lays out breadth-first, so when there
isn't room the smallest, deepest detail is what gets dropped. Folders too small to show their contents are drawn in the color
of the file type that takes the most space inside them.

### App uninstaller

`macos/Sources/MacCleaner/Apps/AppsScanner.swift`:

- **Finding apps:** it lists the app folders (and one level of subfolders, like `Utilities`).
- **Measuring:** it measures every app in parallel.
- **Finding leftovers:** it reads each relevant `~/Library` folder once, then matches entries by bundle ID.
- **"Last opened":** it uses Spotlight's record, falling back to when the app's program was last read, since Spotlight often
  has no entry for apps opened from the Dock.

### Cleanup scans

Each category scan runs on its own background task, reports progress through a lock-guarded object the UI samples a few times
a second, and stops right away when cancelled. Before anything is removed, overlapping selections are de-duplicated: the same
file found by two categories, or something inside a folder that's also being removed.

### Project layout

| Path | What's there |
| --- | --- |
| `macos/` | The native macOS app (SwiftUI) |
| `macos/Sources/MacCleaner/Scanning` | Cleanup-category scanners |
| `macos/Sources/MacCleaner/Explorer` | Disk Explorer: bulk scanner, tree model, treemap layout |
| `macos/Sources/MacCleaner/Apps` | App uninstaller: app and leftover discovery, uninstall |
| `macos/Sources/MacCleaner/Cleaning` | Removal engine |
| `macos/Sources/MacCleaner/Views` | SwiftUI screens |
| `macos/AppBundle/` | `Info.plist` and app icon |
| `macos/scripts/` | `build-app.sh` (build/install), `release.sh` (universal `.dmg`/`.zip`), `make-icon.swift` (regenerate the icon) |

---

## Known limitations

- Leftover detection covers your user `~/Library` only, not system-wide `/Library` files that some installers add.
- The download isn't notarized, so macOS needs a one-time "Open Anyway" (see [Install](#install)).
- Release builds include an Intel version, but it has only been tested on Apple Silicon.
- There are no automated tests yet. The scanners were checked against folders with known contents, and the Disk Explorer's
  totals against `du`.
- Without Full Disk Access, some folders (the Trash, Mail, iPhone backups, other apps' data) can't be scanned.

---

## Vibe-coded disclaimer

### How this was made

Mac Cleaner was **vibe coded**. All of the code was written by **Claude Opus 5.5**, Anthropic's AI model, working in
[Claude Code](https://claude.com/claude-code) over one long conversation. The human side of the project:

- set the direction ("make it work like WizTree", "more color, no grey", "we should also see apps and delete them")
- tried the app and reported what felt wrong
- made the calls on scope, license and publishing

The code was **not written or reviewed line by line by a person**.

### What was actually checked

The AI tested its own work as it went:

- **Scanners:** run against throwaway folders with known contents (duplicates, APFS clones, hard links, stale
  `node_modules`, a fake Photos library).
- **Disk Explorer totals:** compared with `du`, matching to the kilobyte on the folders tested.
- **Move to Trash and uninstall:** run for real on dummy files and a fake app with fake leftovers, confirming that the right
  things moved and that unticked items stayed.
- **Every screen:** rendered in light and dark mode and inspected.

That testing caught real problems before release, which is why you should read the code:

- the Disk Explorer would have let you trash files from inside apps and the Photos library
- uninstalling a Steam shortcut would have taken the game's save files
- a blocked folder was reported as "Nothing found"

### What hasn't been checked

- There's no automated test suite.
- It hasn't been tested on Intel Macs, on other people's Macs, or across many macOS versions and setups.
- The Finder password path for removing system-owned apps hasn't been exercised end to end.
- Whole-disk scans with Full Disk Access granted have only been run on the developer's Mac.

### Using it sensibly

- **Have a backup** (e.g. Time Machine) before cleaning anything you care about.
- **Look at what's selected** before you confirm. Pre-selected means "rebuilt automatically", not "reviewed by a human".
- **Check the Trash before emptying it.** Almost everything Mac Cleaner removes goes there first, and the few permanent
  actions are labelled **Permanent**.

The software is provided "as is", without warranty of any kind (see the [MIT license](LICENSE)). Mac Cleaner isn't affiliated
with Apple, Anthropic, or WizTree.

Bug reports, reviews and pull requests are very welcome. A second pair of human eyes on the deletion code would be especially
valuable.

## License

MIT. See [LICENSE](LICENSE).
