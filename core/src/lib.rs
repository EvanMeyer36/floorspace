//! Cross-platform engine behind Mac Cleaner (macOS, Windows, Linux).
//!
//! - [`tree`]: WizTree-style scan of a disk or folder into a size-sorted tree
//! - [`treemap`]: squarified treemap layout of that tree
//! - [`cleanup`]: per-OS junk (caches, logs, developer tool leftovers, old downloads, trash)
//! - [`search`]: one walk of a folder for large files, duplicates and stale `node_modules`
//! - [`remove`]: moving things to the OS trash, with the safety rules every UI shares
//! - [`apps`]: installed apps and uninstalling them with their leftovers
//!
//! Nothing here deletes anything unless a `remove` function is called with explicit items.

pub mod apps;
pub mod cleanup;
pub mod filetype;
pub mod fsutil;
pub mod progress;
pub mod remove;
pub mod search;
pub mod tree;
pub mod treemap;

pub use filetype::FileType;
pub use progress::Progress;
