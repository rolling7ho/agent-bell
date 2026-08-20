import Darwin
import Foundation

enum DurableFileWriteError: Error {
    case openFailed
    case writeFailed
    case syncFailed
    case replaceFailed
}

enum DurableFileWriter {
    static func write(
        _ data: Data,
        to destination: URL,
        permissions: mode_t = S_IRUSR | S_IWUSR
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            permissions
        )
        guard descriptor >= 0 else {
            throw DurableFileWriteError.openFailed
        }
        var shouldRemoveTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        var bytesWritten = 0
        let wroteAllBytes = data.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else {
                return buffer.isEmpty
            }
            while bytesWritten < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    buffer.count - bytesWritten
                )
                guard result > 0 else { return false }
                bytesWritten += result
            }
            return true
        }
        guard wroteAllBytes else {
            throw DurableFileWriteError.writeFailed
        }
        guard fchmod(descriptor, permissions) == 0,
              fsync(descriptor) == 0
        else {
            throw DurableFileWriteError.syncFailed
        }
        guard Darwin.rename(temporaryURL.path, destination.path) == 0 else {
            throw DurableFileWriteError.replaceFailed
        }
        shouldRemoveTemporaryFile = false
        try syncDirectory(containing: destination)
    }

    static func syncDirectory(containing url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw DurableFileWriteError.openFailed
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DurableFileWriteError.syncFailed
        }
    }
}
