// One running app owns its physical Application Support directory until exit. Older builds that do not take the advisory lock can still write there.
import Darwin
import Foundation

public final class ProfileOwnership {
    private let descriptor: Int32

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
