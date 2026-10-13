import Foundation

/// Writes a rendered transcript straight to disk for `save_transcript`, so
/// the bytes never pass through the MCP client.
///
/// ## Why this exists
///
/// Copying a transcript to a file *through* the model means the model
/// re-generates every character as output tokens. For Hebrew that is close
/// to one token per character: a 40 KB transcript of a 20-minute meeting is
/// 12–15k output tokens, about three minutes of pure generation, where the
/// helper can write the same file in milliseconds. So when the caller only
/// wants the file, the helper writes it and the reply carries the path and
/// size — not the text.
///
/// ## What it refuses
///
/// - **Relative paths.** The helper's working directory is whatever the MCP
///   client launched it with, which the caller cannot see; a relative path
///   would land somewhere it did not mean. `~` is expanded.
/// - **An existing file, unless `overwrite`.** A transcript export should
///   not silently replace whatever was there. The no-overwrite write ends
///   in `renamex_np(…, RENAME_EXCL)`, which the kernel refuses atomically
///   when the name exists, so a file created between the check and the
///   write is not replaced either.
/// - **A missing parent directory.** Creating directories on a guess is how
///   a typo becomes a stray folder tree.
/// - **Anything inside Mila's own data** — the app-support root and the
///   (possibly relocated) recordings directory. Overwriting `recordings.json`
///   or an audio sidecar with transcript text would corrupt the library, and
///   no export belongs there.
///
/// Like the access gate this is not a privilege boundary: `mila-mcp` runs as
/// the user and can write wherever they can. These checks stop mistakes.
struct TranscriptFileWriter: Sendable {

    enum WriteError: Error, CustomStringConvertible {
        case notAbsolute(String)
        case parentMissing(String)
        case exists(String)
        case insideMilaData(String)
        case failed(String, String)

        var description: String {
            switch self {
            case .notAbsolute(let path):
                return "path must be absolute (or start with ~), got \"\(path)\""
            case .parentMissing(let dir):
                return "The folder to save into does not exist: \(dir)"
            case .exists(let path):
                return "\(path) already exists; pass overwrite: true to replace it, or choose another path"
            case .insideMilaData(let path):
                return "Cannot save inside Mila's own data directory (\(path)); choose a path outside it"
            case .failed(let path, let reason):
                return "Could not write \(path): \(reason)"
            }
        }
    }

    /// Directories nothing may be written into. Resolved by the caller from
    /// the same root the reader uses, so a relocated library is covered too.
    let protectedDirectories: [URL]

    /// Resolves `rawPath` to the file to write. An existing directory gets
    /// `defaultFileName` appended, so "save it to ~/Downloads" works without
    /// the caller inventing a name.
    func destination(for rawPath: String, defaultFileName: String) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw WriteError.notAbsolute(rawPath) }
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            url = url.appendingPathComponent(defaultFileName)
        }
        let parent = url.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw WriteError.parentMissing(parent.path)
        }
        // Compare canonical paths: `/var` vs `/private/var`, or a symlinked
        // parent pointing into the store, must not slip past the check.
        let canonical = Self.canonical(parent).appendingPathComponent(url.lastPathComponent)
        for protected in protectedDirectories {
            let dir = Self.canonical(protected).path
            if canonical.path == dir || canonical.path.hasPrefix(dir + "/") {
                throw WriteError.insideMilaData(canonical.path)
            }
        }
        return canonical
    }

    /// Writes `text` as UTF-8 to `url` and returns the byte count.
    func write(_ text: String, to url: URL, overwrite: Bool) throws -> Int {
        let data = Data(text.utf8)
        let fm = FileManager.default
        if overwrite {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw WriteError.failed(url.path, error.localizedDescription)
            }
            return data.count
        }
        guard !fm.fileExists(atPath: url.path) else { throw WriteError.exists(url.path) }
        // Same directory, so the final step is a rename on one volume. The
        // `fileExists` check above is only for the friendly early error;
        // `RENAME_EXCL` is what actually guarantees nothing is replaced.
        let temp = url.deletingLastPathComponent()
            // Not derived from the target's name, which may already be
            // near the 255-byte limit — any affix would push it over.
            .appendingPathComponent(".mila-save-\(UUID().uuidString).partial")
        do {
            try data.write(to: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw WriteError.failed(url.path, error.localizedDescription)
        }
        guard renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            if code == EEXIST { throw WriteError.exists(url.path) }
            throw WriteError.failed(url.path, String(cString: strerror(code)))
        }
        return data.count
    }

    /// `"<yyyy-MM-dd> <title>.<ext>"`, with the characters a macOS path
    /// component cannot hold (or that Finder mangles) replaced.
    static func defaultFileName(title: String, createdAt: Date, fileExtension: String) -> String {
        let day = createdAt.formatted(Date.ISO8601FormatStyle(timeZone: .current)
            .year().month().day())
        let disallowed = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters).union(.newlines)
        var cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map {
            disallowed.contains($0) ? "-" : $0
        })).trimmingCharacters(in: .whitespaces)
        // A leading dot would hide the file; keep the name visible.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        // APFS caps a name at 255 UTF-8 BYTES, not characters — Hebrew is 2
        // bytes a letter, emoji 4 — so budget in bytes, cutting only between
        // characters. 200 leaves room for the date and the extension.
        var budget = 200
        cleaned = String(cleaned.prefix { character in
            budget -= character.utf8.count
            return budget >= 0
        }).trimmingCharacters(in: .whitespaces)
        let stem = cleaned.isEmpty ? day : "\(day) \(cleaned)"
        return "\(stem).\(fileExtension)"
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
