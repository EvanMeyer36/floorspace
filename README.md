# Mac Cleaner

A native macOS app (SwiftUI, macOS 14+) for finding out what's filling your disk and safely clearing it.

Requires macOS 14 or later and Apple's Command Line Tools (`xcode-select --install`); full Xcode isn't needed.

## Install / update

```bash
./scripts/build-app.sh --install
```

This builds `Mac Cleaner.app` and copies it to `/Applications`. Without `--install` it only builds into `build/`.
For quick development runs, `swift run` also works.

## What it does

- **Overview**: disk usage bar, one-click **Smart Scan** of every category, and **Clean Selected**.
- **Disk Explorer** (WizTree-style): scans a whole disk or folder in seconds using bulk directory reads on every CPU core. It shows:
  - a size-sorted folder tree with % of parent
  - a **Largest Files** list of the 1,000 biggest files anywhere on the disk
  - a file-type breakdown
  - a treemap colored by file type (images, video, apps & code, audio, documents, data & AI models, archives & disk images,
    other)

  To use it:
  - Double-click a block to zoom in, and click a file type or legend entry to highlight it.
  - Select several items with ⌘/⇧-click in the lists or ⌘-click on the map, then Show in Finder or Move to Trash all at once.
- **Cleanup categories**: App caches & logs, Developer junk (Xcode, simulators, Docker, npm/yarn/pnpm/pip/cargo/Gradle/Go,
  stale `node_modules`), iPhone backups & Mail attachments, old Downloads, large files, duplicates (content-hashed, skipping
  APFS clones and hard links), and the Trash.

## Safety

- Scanning never changes anything.
- Only items marked **Safe** are pre-selected, and they're all things apps regenerate.
- Everything goes to the **Trash** except: emptying the Trash itself, and Docker/simulator cleanup, which are done by those tools.
  Both are labelled **Permanent** and called out in the confirmation.
- The Disk Explorer only allows trashing items inside your home folder or `/Applications`. It never removes the standard
  top-level folders (Documents, Library, …) or files from inside an app bundle, which would break the app.
- `~/Library` is never searched file-by-file for large files or duplicates.

## Permissions

macOS asks the first time the app looks in Desktop, Documents or Downloads. The Trash, iPhone backups and some app data
need **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access). The app links straight there whenever
something was blocked. The app is signed ad-hoc, so after a rebuild macOS may ask for these again.

## Layout

- `Sources/MacCleaner/Scanning`: cleanup-category scanners
- `Sources/MacCleaner/Explorer`: Disk Explorer: bulk scanner (`getattrlistbulk`), tree model, treemap layout
- `Sources/MacCleaner/Cleaning`: removal engine
- `Sources/MacCleaner/Views`: SwiftUI screens
- `AppBundle/`: Info.plist and icon; `scripts/`: build and icon scripts

## License

MIT. See [LICENSE](LICENSE).
