import Foundation
import SwiftUI

/// File-type groups for coloring the treemap, one per slot of the 8-hue
/// validated palette. In a treemap any two colors can touch, and past three
/// hues some pairs get hard to tell apart for color-blind readers, so every
/// color is backed by text: the legend, the hover tooltip, the File Types
/// table, and click-to-highlight.
enum FileType: Int, CaseIterable, Identifiable {
    case images
    case video
    case appsAndCode
    case audio
    case documents
    case data
    case archives
    case other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .images: return "Images"
        case .video: return "Video"
        case .appsAndCode: return "Apps & code"
        case .audio: return "Music & audio"
        case .documents: return "Documents"
        case .data: return "Data & AI models"
        case .archives: return "Archives & disk images"
        case .other: return "Other"
        }
    }

    var color: Color {
        switch self {
        case .images: return Color(light: NSColor(hex: 0x2a78d6), dark: NSColor(hex: 0x3987e5))
        case .video: return Color(light: NSColor(hex: 0xeb6834), dark: NSColor(hex: 0xd95926))
        case .appsAndCode: return Color(light: NSColor(hex: 0x1baf7a), dark: NSColor(hex: 0x199e70))
        case .other: return Color(light: NSColor(hex: 0xeda100), dark: NSColor(hex: 0xc98500))
        case .audio: return Color(light: NSColor(hex: 0xe87ba4), dark: NSColor(hex: 0xd55181))
        case .documents: return Color(light: NSColor(hex: 0x008300), dark: NSColor(hex: 0x008300))
        case .data: return Color(light: NSColor(hex: 0x6250d6), dark: NSColor(hex: 0x9085e9))
        case .archives: return Color(light: NSColor(hex: 0xe34948), dark: NSColor(hex: 0xe66767))
        }
    }

    private static let byExtension: [String: FileType] = {
        let groups: [(FileType, String)] = [
            (.images, "jpg jpeg png heic heif gif tif tiff webp bmp raw cr2 cr3 nef arw dng orf rw2 psd svg ico icns avif jxl"),
            (.video, "mov mp4 m4v avi mkv webm wmv mpg mpeg 3gp mts braw prores flv"),
            (.audio, "mp3 m4a m4b aac wav aif aiff flac ogg opus caf alac wma mid midi als asd adg"),
            (.documents, "pdf doc docx xls xlsx ppt pptx pages numbers key txt md rtf csv epub odt ods tex"),
            (.archives, "zip dmg pkg mpkg iso xip tar gz tgz bz2 xz 7z rar zst lz4 img ipsw sparseimage vmdk qcow2 vdi hdd ova"),
            (.data, "db sqlite sqlite3 realm dat bin data weights gguf safetensors pt pth onnx mlmodel ckpt npy npz parquet h5 log plist cache idx pack"),
            // No extension: on a Mac that's mostly app and command-line binaries.
            (.appsAndCode, " dylib so a o car nib js mjs cjs ts tsx jsx json py pyc rb go rs swift c cc h hpp cpp m mm java jar class kt wasm node map lock whl gem dll exe pdb swiftmodule swiftinterface ll bc metallib html css sh xml yaml yml toml asar pak strings"),
        ]
        var map: [String: FileType] = [:]
        for (type, list) in groups {
            for ext in list.split(separator: " ", omittingEmptySubsequences: false) { map[String(ext)] = type }
        }
        return map
    }()

    static func of(extension ext: String) -> FileType {
        byExtension[ext] ?? .other
    }

    /// Index of the biggest entry in a per-type size breakdown.
    static func dominant(in sizes: [Int64]) -> FileType? {
        guard let best = sizes.indices.max(by: { sizes[$0] < sizes[$1] }), sizes[best] > 0 else { return nil }
        return FileType(rawValue: best)
    }
}

/// One folder or file in the Disk Explorer tree.
///
/// Small files aren't kept individually (a full disk can hold millions); each
/// folder rolls them into a single "smaller files" entry so memory stays bounded.
final class DiskNode: Identifiable {
    enum Kind {
        case folder
        case file
        /// Small files in a folder, grouped.
        case smallFiles(count: Int)
        /// Space on the disk that the scan couldn't attribute to a folder.
        case unattributed
    }

    var id = 0
    let name: String
    let kind: Kind
    weak var parent: DiskNode?
    var size: Int64
    var fileCount: Int
    var children: [DiskNode] = []
    /// Folder only: macOS refused to list it.
    var isUnreadable = false
    /// Folder only: another volume mounted here; dropped from the tree after the scan.
    var isOtherVolume = false
    /// Folder only: set on the scan root so the full path can be rebuilt.
    var rootPath: String?
    /// Folders and grouped small files: the file type taking the most space inside.
    var dominantType: FileType?
    /// Bytes per FileType while totals are being added up; cleared afterwards.
    var typeSizes: [Int64]?

    init(name: String, kind: Kind, size: Int64 = 0, fileCount: Int = 0, parent: DiskNode?) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.parent = parent
    }

    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    /// Real file or folder on disk (not a grouped/pseudo entry).
    var isOnDisk: Bool {
        switch kind {
        case .folder, .file: return true
        case .smallFiles, .unattributed: return false
        }
    }

    var fileExtension: String {
        guard case .file = kind, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    var fileType: FileType? {
        guard case .file = kind else { return nil }
        return FileType.of(extension: fileExtension)
    }

    /// The color group this node is drawn with: its own type for files, the main type inside otherwise.
    var displayType: FileType? {
        fileType ?? dominantType
    }

    /// For the tree table: nil marks a row without a disclosure triangle.
    var childNodes: [DiskNode]? {
        isFolder && !children.isEmpty ? children : nil
    }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let parentPath = parent.path
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }

    var url: URL? {
        isOnDisk ? URL(fileURLWithPath: path) : nil
    }

    var ancestors: [DiskNode] {
        var chain: [DiskNode] = []
        var node = parent
        while let current = node {
            chain.insert(current, at: 0)
            node = current.parent
        }
        return chain
    }

    func isDescendant(of other: DiskNode) -> Bool {
        var node = parent
        while let current = node {
            if current === other { return true }
            node = current.parent
        }
        return false
    }

    /// Detaches this node and takes its size out of every ancestor.
    func removeFromTree() {
        var node = parent
        while let current = node {
            current.size -= size
            current.fileCount -= fileCount
            node = current.parent
        }
        parent?.children.removeAll { $0 === self }
        parent = nil
    }
}

struct TypeStat: Identifiable {
    let ext: String
    var size: Int64
    var count: Int
    var id: String { ext }
    var fileType: FileType { FileType.of(extension: ext) }
    var label: String { ext.isEmpty ? "(no extension)" : "." + ext }
}
