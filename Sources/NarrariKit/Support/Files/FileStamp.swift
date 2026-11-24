import Darwin
import Foundation

// Whether a file changed since it was last read, by this app or the narrari command: any write changes one of these.
struct FileStamp: Equatable, Sendable {
    private let inode: UInt64
    let size: Int64
    private let seconds: Int
    private let nanoseconds: Int

    // Nil when there is no file.
    init?(_ url: URL) {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ $0.map { stat($0, &info) } }) == 0 else { return nil }
        inode = info.st_ino
        size = info.st_size
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
    }
}
