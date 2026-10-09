import Foundation
import Darwin
import Darwin.membership

// Pin every ancestor, and reject locations another account can replace.
// Engine paths remain safe while these directories retain their trusted permissions.
final class PinnedDestinationDirectory {
    let url: URL
    private let ancestors: [Int32]
    var descriptor: Int32 { ancestors.last! }

    init(_ url: URL) throws {
        guard let resolved = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        self.url = canonical
        var opened: [Int32] = []
        do {
            let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            opened.append(root)
            try Self.checkPermissions(root)
            for component in canonical.pathComponents.dropFirst() {
                let next = openat(opened.last!, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                opened.append(next)
                try Self.checkPermissions(next)
            }
        } catch {
            opened.forEach { close($0) }
            throw error
        }
        ancestors = opened
    }
    deinit { ancestors.forEach { close($0) } }

    func verify() throws {
        for directory in ancestors { try Self.checkPermissions(directory) }
        var pinned = stat(), current = stat()
        guard fstat(descriptor, &pinned) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard lstat(url.path, &current) == 0,
              current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino else {
            throw KkukError.sourceChanged
        }
    }
    private static func checkPermissions(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // The sticky bit protects our directory entries in system temporary folders.
        guard metadata.st_uid == geteuid() || metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0 || metadata.st_mode & mode_t(S_ISVTX) != 0 else {
            throw KkukError.unsafeDestination
        }
        guard let acl = acl_get_fd(descriptor) else {
            let code = errno
            if code == ENOENT || code == ENOATTR || code == ENOTSUP { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var entryID = Int32(ACL_FIRST_ENTRY.rawValue)
        let writeMask = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE_CHILD, ACL_DELETE,
                         ACL_WRITE_SECURITY, ACL_CHANGE_OWNER].reduce(UInt64(0)) { $0 | UInt64($1.rawValue) }
        while acl_get_entry(acl, entryID, &entry) == 0 {
            entryID = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG
            var mask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset_mask_np(entry, &mask) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if tag == ACL_EXTENDED_ALLOW && mask & writeMask != 0 {
                guard let qualifier = acl_get_qualifier(entry) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                defer { acl_free(qualifier) }
                var identity: id_t = 0
                var identityType: Int32 = 0
                let result = mbr_uuid_to_id(qualifier.assumingMemoryBound(to: UInt8.self), &identity, &identityType)
                // These principals already control the directory or the entire system.
                // Groups, other users and unresolved identities remain untrusted.
                guard result == 0, identityType == ID_TYPE_UID,
                      identity == geteuid() || identity == 0 else {
                    throw KkukError.unsafeDestination
                }
            }
        }
    }
    func removeTemporary(_ descriptor: Int32, name: String) {
        // Cleanup stays attached to the opened objects even if their paths move.
        let duplicate = dup(descriptor)
        if duplicate >= 0, let directory = fdopendir(duplicate) {
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if child != "." && child != ".." { _ = unlinkat(descriptor, child, 0) }
            }
        }
        else if duplicate >= 0 { close(duplicate) }
        var expected = stat(), current = stat()
        if fstat(descriptor, &expected) == 0,
           fstatat(self.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
           expected.st_dev == current.st_dev && expected.st_ino == current.st_ino {
            _ = unlinkat(self.descriptor, name, AT_REMOVEDIR)
        }
    }
}

enum ArchiveFileAccess {
    static func restrictAccess(descriptor: Int32, directory: Bool) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let expectedType = mode_t(directory ? S_IFDIR : S_IFREG)
        guard metadata.st_mode & mode_t(S_IFMT) == expectedType else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        // Mode bits alone do not remove inherited grants on macOS.
        guard let acl = acl_init(0) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if acl_set_fd(descriptor, acl) != 0 {
            let code = errno
            // Filesystems without extended ACLs can still enforce POSIX permissions.
            guard code == ENOTSUP else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        let permissions: mode_t = directory ? 0o700 : 0o600
        guard fchmod(descriptor, permissions) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard metadata.st_mode & 0o777 == permissions else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
    }
    static func nameLimit(directoryDescriptor: Int32) throws -> Int {
        errno = 0
        let limit = fpathconf(directoryDescriptor, _PC_NAME_MAX)
        let code = errno
        if limit < 0 && code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        return limit > 0 ? Int(limit) : 255
    }
    static func writePrivateList(_ contents: String, directoryDescriptor: Int32, name: String = "excluded-paths.txt") throws {
        let descriptor = openat(directoryDescriptor, name,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        try restrictAccess(descriptor: descriptor, directory: false)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: Data(contents.utf8))
    }
}
