import Darwin
import Foundation

public enum BackingFile {
	public static func create(at url: URL, size: Int) throws {
		let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else { throw DiskError.io(errno: errno) }
		defer { close(descriptor) }
		guard ftruncate(descriptor, off_t(size)) == 0 else { throw DiskError.io(errno: errno) }
	}

	public static func restore(_ url: URL, from pristine: URL) throws {
		guard unlink(url.path) == 0 || errno == ENOENT else { throw DiskError.io(errno: errno) }
		guard clonefile(pristine.path, url.path, 0) == 0 else { throw DiskError.io(errno: errno) }
	}
}
