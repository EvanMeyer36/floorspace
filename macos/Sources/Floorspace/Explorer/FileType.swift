import SwiftUI

/// File-type groups for coloring the treemap, one per slot of the 8-hue validated palette. The
/// engine decides each file's group; raw values match its JSON. In a treemap any two colors can
/// touch, and past three hues some pairs get hard to tell apart for color-blind readers, so every
/// color is backed by text: the legend, the hover tooltip, the File Types table, and
/// click-to-highlight.
enum FileType: String, CaseIterable, Identifiable, Decodable, Sendable {
    case images
    case video
    case appsAndCode
    case audio
    case documents
    case data
    case archives
    case other

    var id: String { rawValue }

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
}
