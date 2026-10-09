import Foundation

/// Native file primitives for the engine's `ExecutionEnv` (`engine/src/env.ts`), shaped like the node:fs calls
/// pi-durable's Node environment makes. Paths arrive absolute; the engine resolves them.
///
/// Failures reply with `"<ERRNO>: <message>"` (`ENOENT`, `EACCES`, `ENOTDIR`, ...) so the engine can map them to
/// pi-durable's `FileError` codes. Binary data travels base64-encoded. Work runs off the main actor.
@MainActor
public final class FileService {
    public init() {}

    public func install(on engine: PiEngine) {
        engine.register(service: "fs") { method, params in
            let arguments = JSONValue(bridged: params)
            return try await Task.detached { try FileOperations.perform(method, arguments) }.value.bridged
        }
    }
}

struct FileServiceError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { "\(code): \(message)" }

    static func posix(_ number: Int32 = errno, path: String) -> FileServiceError {
        let names: [Int32: String] = [
            ENOENT: "ENOENT", EACCES: "EACCES", EPERM: "EPERM", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR",
            EINVAL: "EINVAL", EEXIST: "EEXIST", ENOTEMPTY: "ENOTEMPTY", ELOOP: "ELOOP", ENAMETOOLONG: "ENAMETOOLONG",
            ENOSPC: "ENOSPC", EXDEV: "EXDEV", EBUSY: "EBUSY", EIO: "EIO",
        ]
        return FileServiceError(code: names[number] ?? "EUNKNOWN", message: "\(String(cString: strerror(number))), '\(path)'")
    }
}

enum FileOperations {
    static func perform(_ method: String, _ arguments: JSONValue) throws -> JSONValue {
        func path(_ key: String = "path") throws -> String {
            guard let value = arguments[key]?.string, value.hasPrefix("/") else {
                throw FileServiceError(code: "EINVAL", message: "\(key) must be an absolute path")
            }
            return value
        }
        switch method {
        case "stat": return try info(at: path())
        case "readdir": return try listDirectory(path())
        case "readText": return .string(String(decoding: try readAll(path()), as: UTF8.self))
        case "readBinary": return .string(try readAll(path()).base64EncodedString())
        case "read":
            let (data, count) = try read(path(), offset: Int64(arguments["offset"]?.number ?? 0), length: Int(arguments["length"]?.number ?? 65_536))
            return .object(["data": .string(data.base64EncodedString()), "bytesRead": .number(Double(count))])
        case "write":
            let content = try arguments["data"]?.string.map { encoded in
                guard let data = Data(base64Encoded: encoded) else { throw FileServiceError(code: "EINVAL", message: "invalid base64") }
                return data
            } ?? Data((arguments["text"]?.string ?? "").utf8)
            try write(path(), content, append: arguments["append"]?.bool ?? false)
            return .null
        case "truncate":
            let target = try path()
            guard truncate(target, off_t(arguments["size"]?.number ?? 0)) == 0 else { throw FileServiceError.posix(path: target) }
            return .null
        case "fsync":
            let target = try path()
            let descriptor = open(target, O_RDWR)
            guard descriptor >= 0 else { throw FileServiceError.posix(path: target) }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw FileServiceError.posix(path: target) }
            return .null
        case "rename":
            let (source, destination) = (try path("from"), try path("to"))
            guard rename(source, destination) == 0 else { throw FileServiceError.posix(path: source) }
            return .null
        case "copy":
            // FileManager clones on APFS, so copying a directory costs little.
            let (source, destination) = (try path("from"), try path("to"))
            do {
                try FileManager.default.copyItem(atPath: source, toPath: destination)
            } catch let error as CocoaError {
                let code = error.code == .fileReadNoSuchFile ? "ENOENT" : error.code == .fileWriteFileExists ? "EEXIST" : "EIO"
                throw FileServiceError(code: code, message: "\(error.localizedDescription), '\(source)'")
            }
            return .null
        case "realpath":
            let target = try path()
            guard let resolved = realpath(target, nil) else { throw FileServiceError.posix(path: target) }
            defer { free(resolved) }
            return .string(String(cString: resolved))
        case "mkdir":
            try makeDirectory(path(), recursive: arguments["recursive"]?.bool ?? true)
            return .null
        case "rm":
            try remove(path(), recursive: arguments["recursive"]?.bool ?? false, force: arguments["force"]?.bool ?? false)
            return .null
        case "mkdtemp":
            let prefix = arguments["prefix"]?.string ?? "tmp-"
            var template = Array((NSTemporaryDirectory() + prefix + "XXXXXX").utf8CString)
            guard mkdtemp(&template) != nil else { throw FileServiceError.posix(path: NSTemporaryDirectory()) }
            return .string(String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        default:
            throw EngineError.unknownMethod("fs.\(method)")
        }
    }

    /// lstat semantics: symlinks are reported as symlinks, not followed.
    static func info(at path: String) throws -> JSONValue {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw FileServiceError.posix(path: path) }
        let kind: String
        switch status.st_mode & S_IFMT {
        case S_IFREG: kind = "file"
        case S_IFDIR: kind = "directory"
        case S_IFLNK: kind = "symlink"
        default: throw FileServiceError(code: "EINVAL", message: "Unsupported file type, '\(path)'")
        }
        let modified = Double(status.st_mtimespec.tv_sec) * 1000 + Double(status.st_mtimespec.tv_nsec) / 1_000_000
        return .object([
            "name": .string((path as NSString).lastPathComponent),
            "path": .string(path),
            "kind": .string(kind),
            "size": .number(Double(status.st_size)),
            "mtimeMs": .number(modified),
        ])
    }

    static func listDirectory(_ path: String) throws -> JSONValue {
        guard let directory = opendir(path) else { throw FileServiceError.posix(path: path) }
        defer { closedir(directory) }
        var entries: [JSONValue] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if name == "." || name == ".." { continue }
            let child = path.hasSuffix("/") ? path + name : path + "/" + name
            // Unsupported kinds (sockets, devices) are skipped, as in pi-durable's Node environment.
            if let info = try? info(at: child) { entries.append(info) }
        }
        return .array(entries)
    }

    static func readAll(_ path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw FileServiceError.posix(path: path) }
        defer { close(descriptor) }
        var status = stat()
        if fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR { throw FileServiceError.posix(EISDIR, path: path) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { throw FileServiceError.posix(path: path) }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }

    static func read(_ path: String, offset: Int64, length: Int) throws -> (Data, Int) {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw FileServiceError.posix(path: path) }
        defer { close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: max(0, length))
        let count = pread(descriptor, &buffer, buffer.count, off_t(offset))
        if count < 0 { throw FileServiceError.posix(path: path) }
        return (Data(buffer.prefix(count)), count)
    }

    static func write(_ path: String, _ data: Data, append: Bool) throws {
        try makeDirectory((path as NSString).deletingLastPathComponent, recursive: true)
        let descriptor = open(path, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0o644)
        guard descriptor >= 0 else { throw FileServiceError.posix(path: path) }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + written, bytes.count - written)
                if count < 0 { throw FileServiceError.posix(path: path) }
                written += count
            }
        }
    }

    static func makeDirectory(_ path: String, recursive: Bool) throws {
        if recursive {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return }
                throw FileServiceError.posix(ENOTDIR, path: path)
            }
            try makeDirectory((path as NSString).deletingLastPathComponent, recursive: true)
        }
        guard mkdir(path, 0o755) == 0 || (recursive && errno == EEXIST) else { throw FileServiceError.posix(path: path) }
    }

    static func remove(_ path: String, recursive: Bool, force: Bool) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if force && errno == ENOENT { return }
            throw FileServiceError.posix(path: path)
        }
        if status.st_mode & S_IFMT == S_IFDIR {
            guard recursive else { throw FileServiceError.posix(EISDIR, path: path) }
            for name in try FileManager.default.contentsOfDirectory(atPath: path) {
                try remove((path as NSString).appendingPathComponent(name), recursive: true, force: force)
            }
            guard rmdir(path) == 0 else { throw FileServiceError.posix(path: path) }
        } else {
            guard unlink(path) == 0 else { throw FileServiceError.posix(path: path) }
        }
    }
}
