import CryptoKit
import Foundation

/// A session's workspace files as sync sees them (`SessionSync`): each by its path in the workspace, with its SHA-256
/// and size.
struct FileManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var hash: String
        var size: Int
    }

    var files: [String: File] = [:]
}

/// Reads and writes workspaces for sync. What Share Session leaves behind stays behind here too (installed packages and
/// caches, which the other device makes again), and so do files too large to send.
enum WorkspaceFiles {
    static let leftBehind: Set<String> = [".python", "node_modules", "__pycache__", ".cache"]
    static let largest = 100 * 1024 * 1024

    /// A file as last hashed: its hash holds while its size and modification date do.
    struct Known: Codable, Sendable {
        var size: Int
        var modified: Double
        var hash: String
    }

    /// The workspace's files, hashing only the ones whose size or modification date changed since `known` (kept up to
    /// date); and the ones too large to send.
    static func scan(_ workspace: URL, known: inout [String: Known]) -> (manifest: FileManifest, skipped: [String]) {
        var manifest = FileManifest()
        var skipped: [String] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: keys) else { return (manifest, []) }
        let prefix = workspace.standardizedFileURL.path.count
        while let file = walker.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, leftBehind.contains(file.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = String(file.standardizedFileURL.path.dropFirst(prefix).trimmingPrefix("/"))
            let size = values?.fileSize ?? 0
            guard size <= largest else {
                skipped.append(path)
                continue
            }
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            seen.insert(path)
            if let cached = known[path], cached.size == size, cached.modified == modified {
                manifest.files[path] = FileManifest.File(hash: cached.hash, size: size)
                continue
            }
            guard let hash = try? sha256(of: file) else { continue }
            known[path] = Known(size: size, modified: modified, hash: hash)
            manifest.files[path] = FileManifest.File(hash: hash, size: size)
        }
        known = known.filter { seen.contains($0.key) }
        return (manifest, skipped)
    }

    /// Makes the workspace hold what `manifest` lists: new and changed files written (their contents by hash from
    /// `contents`), files it doesn't list deleted (what stays behind aside).
    static func apply(_ manifest: FileManifest, to workspace: URL, known: inout [String: Known], contents: @Sendable (String) async throws -> Data) async throws {
        let (here, _) = scan(workspace, known: &known)
        for (path, file) in manifest.files where here.files[path]?.hash != file.hash {
            // Only paths inside the workspace.
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { continue }
            let data = try await contents(file.hash)
            let target = workspace.appending(path: path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            let modified = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            known[path] = Known(size: data.count, modified: modified, hash: file.hash)
        }
        for path in here.files.keys where manifest.files[path] == nil {
            try? FileManager.default.removeItem(at: workspace.appending(path: path))
            known[path] = nil
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
