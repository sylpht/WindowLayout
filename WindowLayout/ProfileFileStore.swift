import Foundation
import CoreGraphics
import Darwin

enum ProfileFileStore {
    static let defaultMaxBytes = 5 * 1024 * 1024

    enum StoreError: LocalizedError {
        case tooLarge(Int)
        case notRegularFile
        case duplicateProfileID
        case invalidGeometry
        case invalidDate
        case invalidByteLimit

        var errorDescription: String? {
            switch self {
            case .tooLarge(let limit): return L.s("Файл расположений превышает допустимый размер: \(limit) байт.", "The profiles file exceeds the \(limit)-byte limit.", "布局文件超过 \(limit) 字节的大小限制。")
            case .notRegularFile: return L.s("По пути расположений находится не обычный файл.", "The profiles path is not a regular file.", "布局路径不是普通文件。")
            case .duplicateProfileID: return L.s("В файле расположений повторяются идентификаторы профилей.", "The profiles file contains duplicate profile IDs.", "布局文件包含重复的配置标识符。")
            case .invalidGeometry: return L.s("В расположении записаны некорректные координаты окна или экрана.", "A profile contains invalid window or screen geometry.", "配置包含无效的窗口或屏幕坐标。")
            case .invalidDate: return L.s("В расположении записана некорректная дата.", "A profile contains an invalid date.", "配置包含无效日期。")
            case .invalidByteLimit: return L.s("Некорректное ограничение размера файла расположений.", "The profiles byte limit is invalid.", "布局文件的大小限制无效。")
            }
        }
    }

    /// A missing file is the only empty-store condition. Existing unreadable or
    /// invalid files must survive so the caller can report or recover them.
    static func read(from url: URL, maxBytes: Int = defaultMaxBytes) throws -> [LayoutProfile]? {
        guard maxBytes >= 0, maxBytes < Int.max else { throw StoreError.invalidByteLimit }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)) {
                return nil
            }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.notRegularFile }
        if let size = attributes[.size] as? NSNumber, size.uint64Value > UInt64(maxBytes) {
            throw StoreError.tooLarge(maxBytes)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, maxBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maxBytes else { throw StoreError.tooLarge(maxBytes) }
        }
        let profiles = try iCloudSync.makeDecoder().decode([LayoutProfile].self, from: data)
        try validate(profiles)
        return profiles
    }

    /// Stage in the destination directory with mode 0600 before writing any data.
    /// A single rename commits the complete file; failures leave the old file intact.
    /// A commit guard can serialize the final replacement with cancellation without
    /// holding the caller's lock during encoding or file synchronization.
    static func write(_ profiles: [LayoutProfile], to url: URL, pretty: Bool,
                      maxBytes: Int = defaultMaxBytes,
                      commit: ((_ replace: () throws -> Void) throws -> Void)? = nil) throws {
        guard maxBytes >= 0 else { throw StoreError.invalidByteLimit }
        try validate(profiles)
        let data = try iCloudSync.makeEncoder(pretty: pretty).encode(profiles)
        guard data.count <= maxBytes else { throw StoreError.tooLarge(maxBytes) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: staged)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        let replace = {
            guard rename(staged.path, url.path) == 0 else { throw posixError() }
        }
        if let commit { try commit(replace) }
        else { try replace() }
    }

    static func validate(_ profiles: [LayoutProfile]) throws {
        var ids = Set<UUID>()
        for profile in profiles {
            guard ids.insert(profile.id).inserted else { throw StoreError.duplicateProfileID }
            for date in [profile.capturedAt, profile.modifiedAt, profile.deletedAt].compactMap({ $0 }) {
                guard date.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidDate }
            }
            for frame in profile.screenFrames { try validate(frame) }
            for window in profile.windows {
                guard window.screenIndex >= 0 else { throw StoreError.invalidGeometry }
                try validate(window.frame)
                try validate(window.normalizedFrame)
            }
        }
    }

    private static func validate(_ frame: CGRect) throws {
        guard [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
              frame.size.width >= 0, frame.size.height >= 0 else { throw StoreError.invalidGeometry }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
