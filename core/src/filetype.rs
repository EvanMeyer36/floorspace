use serde::Serialize;
use std::collections::HashMap;
use std::sync::OnceLock;

/// File-type groups used to color the treemap. One per slot of an 8-hue palette, so every
/// UI can map them to the same colors.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FileType {
    Images,
    Video,
    AppsAndCode,
    Audio,
    Documents,
    Data,
    Archives,
    Other,
}

impl FileType {
    pub const ALL: [FileType; 8] = [
        FileType::Images,
        FileType::Video,
        FileType::AppsAndCode,
        FileType::Audio,
        FileType::Documents,
        FileType::Data,
        FileType::Archives,
        FileType::Other,
    ];

    pub fn index(self) -> usize {
        self as usize
    }

    pub fn title(self) -> &'static str {
        match self {
            FileType::Images => "Images",
            FileType::Video => "Video",
            FileType::AppsAndCode => "Apps & code",
            FileType::Audio => "Music & audio",
            FileType::Documents => "Documents",
            FileType::Data => "Data & AI models",
            FileType::Archives => "Archives & disk images",
            FileType::Other => "Other",
        }
    }

    /// Group for a lowercase extension without the dot ("" for none).
    pub fn of_extension(ext: &str) -> FileType {
        *table().get(ext).unwrap_or(&FileType::Other)
    }

    /// The biggest entry in a per-type size breakdown.
    pub fn dominant(sizes: &[u64; 8]) -> Option<FileType> {
        let (index, &size) = sizes.iter().enumerate().max_by_key(|(_, &s)| s)?;
        (size > 0).then_some(FileType::ALL[index])
    }
}

/// Lowercase extension of a file name: "Photo.JPG" -> "jpg", "Makefile" -> "", ".bashrc" -> "".
pub fn extension(name: &str) -> String {
    match name.rfind('.') {
        Some(0) | None => String::new(),
        Some(dot) if name.len() - dot - 1 <= 12 => name[dot + 1..].to_ascii_lowercase(),
        Some(_) => String::new(),
    }
}

fn table() -> &'static HashMap<&'static str, FileType> {
    static TABLE: OnceLock<HashMap<&'static str, FileType>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let groups: [(FileType, &str); 7] = [
            (FileType::Images, "jpg jpeg png heic heif gif tif tiff webp bmp raw cr2 cr3 nef arw dng orf rw2 psd svg ico icns avif jxl"),
            (FileType::Video, "mov mp4 m4v avi mkv webm wmv mpg mpeg 3gp mts braw prores flv"),
            (FileType::Audio, "mp3 m4a m4b aac wav aif aiff flac ogg opus caf alac wma mid midi als asd adg"),
            (FileType::Documents, "pdf doc docx xls xlsx ppt pptx pages numbers key txt md rtf csv epub odt ods tex"),
            (FileType::Archives, "zip dmg pkg mpkg iso xip tar gz tgz bz2 xz 7z rar zst lz4 img ipsw sparseimage vmdk qcow2 vdi vhd vhdx hdd ova msi cab deb rpm appimage"),
            (FileType::Data, "db sqlite sqlite3 realm dat bin data weights gguf safetensors pt pth onnx mlmodel ckpt npy npz parquet h5 log plist cache idx pack"),
            // No extension: on macOS and Linux that's mostly program binaries.
            (FileType::AppsAndCode, " dylib so a o car nib js mjs cjs ts tsx jsx json py pyc rb go rs swift c cc h hpp cpp m mm java jar class kt wasm node map lock whl gem dll exe sys pdb swiftmodule swiftinterface ll bc metallib html css sh ps1 bat xml yaml yml toml asar pak strings"),
        ];
        let mut map = HashMap::new();
        for (kind, list) in groups {
            for ext in list.split(' ') {
                map.insert(ext, kind);
            }
        }
        map
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extensions() {
        assert_eq!(extension("Photo.JPG"), "jpg");
        assert_eq!(extension("Makefile"), "");
        assert_eq!(extension(".bashrc"), "");
        assert_eq!(extension("archive.tar.gz"), "gz");
        assert_eq!(extension("weird.thisisaverylongextension"), "");
    }

    #[test]
    fn groups() {
        assert_eq!(FileType::of_extension("mov"), FileType::Video);
        assert_eq!(FileType::of_extension("gguf"), FileType::Data);
        assert_eq!(FileType::of_extension(""), FileType::AppsAndCode);
        assert_eq!(FileType::of_extension("xyz"), FileType::Other);
    }

    #[test]
    fn dominant_type() {
        let mut sizes = [0u64; 8];
        assert_eq!(FileType::dominant(&sizes), None);
        sizes[FileType::Video.index()] = 10;
        sizes[FileType::Images.index()] = 3;
        assert_eq!(FileType::dominant(&sizes), Some(FileType::Video));
    }
}
