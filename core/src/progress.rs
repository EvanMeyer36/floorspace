use serde::Serialize;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// Live progress and cancellation for one long-running operation.
///
/// Scans update it from many threads; a UI samples [`Progress::snapshot`] a few times a second.
/// Cheap to clone (it's an `Arc`).
#[derive(Clone, Default)]
pub struct Progress(Arc<Inner>);

#[derive(Default)]
struct Inner {
    items: AtomicU64,
    cancelled: AtomicBool,
    text: Mutex<(String, String)>, // (phase, current path)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub items_seen: u64,
    pub phase: String,
    pub current_path: String,
}

impl Progress {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&self, count: u64, current: &Path) {
        let total = self.0.items.fetch_add(count, Ordering::Relaxed) + count;
        // The UI only samples a few times a second; updating the path string for every folder is wasted work.
        if total % 256 < count.max(1) {
            if let Ok(mut text) = self.0.text.lock() {
                text.1 = current.to_string_lossy().into_owned();
            }
        }
    }

    pub fn set_phase(&self, phase: impl Into<String>) {
        if let Ok(mut text) = self.0.text.lock() {
            text.0 = phase.into();
        }
    }

    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::Relaxed);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Relaxed)
    }

    pub fn snapshot(&self) -> Snapshot {
        let (phase, current_path) = self.0.text.lock().map(|t| t.clone()).unwrap_or_default();
        Snapshot { items_seen: self.0.items.load(Ordering::Relaxed), phase, current_path }
    }
}
