import Foundation

enum ClaudeAccount: String, CaseIterable, Identifiable {
    case personal = "Personal"
    case work = "Work"

    var id: String { rawValue }

    var configDir: String {
        switch self {
        case .personal: return "~/.claude-personal"
        case .work:     return "~/.claude-work"
        }
    }

    var expandedConfigDir: String {
        (configDir as NSString).expandingTildeInPath
    }

    var displayName: String { rawValue }

    var menuBarIcon: String {
        switch self {
        case .personal: return "person.circle"
        case .work:     return "building.2.crop.circle"
        }
    }

    /// True only if the expanded config-dir path exists *and* is a directory.
    /// A stray regular file at the expected path returns false — required by
    /// both the first-run gate (§6) and per-launch validation (§7); the bare
    /// `fileExists(atPath:)` would return true for files too.
    var configDirExists: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: expandedConfigDir,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}
