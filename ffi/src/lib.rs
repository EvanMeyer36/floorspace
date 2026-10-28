//! C interface to the shared engine session, for the native Mac app (Swift).
//!
//! One entry point takes a method name and JSON arguments and returns JSON, which keeps the
//! boundary tiny and lets Swift decode straight into its own types. The methods mirror
//! `floorspace_core::session::Session` one to one, so the Mac app and the desktop app run the same
//! engine code.

use floorspace_core::cleanup::Category;
use floorspace_core::session::{ScanOptions, Session};
use floorspace_core::tree::NodeId;
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::OnceLock;

fn session() -> &'static Session {
    static SESSION: OnceLock<Session> = OnceLock::new();
    SESSION.get_or_init(Session::new)
}

/// Handles one request. Returns a newly allocated JSON string: `{"ok": ...}` or `{"error": "..."}`.
///
/// # Safety
/// `method` and `args_json` must be valid NUL-terminated UTF-8 strings (or null for no arguments).
/// The returned pointer must be released with [`floorspace_free`].
#[no_mangle]
pub unsafe extern "C" fn floorspace_call(method: *const c_char, args_json: *const c_char) -> *mut c_char {
    let read = |p: *const c_char| if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() };
    let (method, args) = (read(method), read(args_json));
    let reply = match std::panic::catch_unwind(|| dispatch(&method, &args)) {
        Ok(Ok(value)) => json!({ "ok": value }),
        Ok(Err(message)) => json!({ "error": message }),
        Err(_) => json!({ "error": format!("The engine hit an internal error in {method}.") }),
    };
    CString::new(reply.to_string()).unwrap_or_default().into_raw()
}

/// Frees a reply from [`floorspace_call`].
///
/// # Safety
/// `reply` must come from `floorspace_call` and not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn floorspace_free(reply: *mut c_char) {
    if !reply.is_null() {
        drop(CString::from_raw(reply));
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Args {
    kind: String,
    path: Option<PathBuf>,
    id: Option<NodeId>,
    ids: Vec<NodeId>,
    item_ids: Vec<String>,
    focus: NodeId,
    width: f64,
    height: f64,
    category: Option<Category>,
    #[serde(flatten)]
    options: ScanOptionsArgs,
    include_sandboxed_data: bool,
    app_id: String,
    keep: Vec<PathBuf>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct ScanOptionsArgs {
    search_root: Option<PathBuf>,
    downloads_age_days: Option<u64>,
    large_file_min_mb: Option<u64>,
}

fn dispatch(method: &str, args: &str) -> Result<Value, String> {
    let a: Args = if args.trim().is_empty() { Args::default() } else { serde_json::from_str(args).map_err(|e| format!("Bad arguments for {method}: {e}"))? };
    let s = session();
    let options = || ScanOptions {
        search_root: a.options.search_root.clone(),
        downloads_age_days: a.options.downloads_age_days,
        large_file_min_mb: a.options.large_file_min_mb,
    };
    let value = match method {
        "platform" => json!(s.platform()),
        "disk_space" => json!(s.disk_space()),
        "progress" => json!(s.progress(&a.kind)),
        "cancel" => json!(s.cancel(&a.kind)),

        "tree_scan" => json!(s.tree_scan(a.path.clone().ok_or("path is required")?)),
        "tree_children" => json!(s.tree_children(a.id.unwrap_or(0))),
        "tree_node" => json!(s.tree_node(a.id.unwrap_or(0))),
        "tree_largest" => json!(s.tree_largest()),
        "tree_types" => json!(s.tree_types()),
        "treemap" => json!(s.treemap(a.focus, a.width, a.height)),
        "tree_selection_size" => json!(s.tree_selection_size(&a.ids)),
        "tree_trash" => json!(s.tree_trash(&a.ids)),

        "junk_scan" => json!(s.junk_scan(&options())),
        "junk_scan_category" => json!(s.junk_scan_category(a.category.ok_or("category is required")?, &options())),
        "clean" => json!(s.clean(&a.item_ids)),

        "apps_list" => json!(s.apps_list(a.include_sandboxed_data)),
        "apps_uninstall" => json!(s.apps_uninstall(&a.app_id, a.keep.clone())?),
        other => return Err(format!("Unknown method {other}")),
    };
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(method: &str, args: &str) -> Value {
        let m = CString::new(method).unwrap();
        let a = CString::new(args).unwrap();
        unsafe {
            let reply = floorspace_call(m.as_ptr(), a.as_ptr());
            let value: Value = serde_json::from_str(CStr::from_ptr(reply).to_str().unwrap()).unwrap();
            floorspace_free(reply);
            value
        }
    }

    #[test]
    fn round_trips_json() {
        assert!(call("platform", "")["ok"]["home"].is_string());
        assert!(call("nope", "{}")["error"].as_str().unwrap().contains("Unknown method"));
        assert!(call("tree_scan", "{}")["error"].as_str().unwrap().contains("path"));
        assert!(call("tree_scan", "{not json")["error"].as_str().unwrap().contains("Bad arguments"));

        let dir = tempfile_dir();
        let overview = call("tree_scan", &json!({ "path": dir }).to_string());
        assert!(overview["ok"]["root"]["size"].as_u64().unwrap() > 0);
        let children = call("tree_children", r#"{"id": 0}"#);
        assert_eq!(children["ok"][0]["name"], "f.bin");
        assert!(call("clean", r#"{"itemIds": ["/etc/hosts"]}"#)["ok"]["cleaned"].as_array().unwrap().is_empty(), "IDs not from a scan are ignored");
    }

    fn tempfile_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("floorspace-ffi-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("f.bin"), vec![1u8; 300_000]).unwrap();
        dir
    }
}
