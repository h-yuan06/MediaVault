import Foundation

enum LikeStore {
    private static let key = "com.mediavault.liked"

    static func isLiked(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, key, nil, 0, 0, 0) > 0
        }
    }

    static func setLiked(_ url: URL, _ liked: Bool) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            if liked {
                var v: UInt8 = 1
                setxattr(path, key, &v, 1, 0, 0)
            } else {
                removexattr(path, key, 0)
            }
        }
    }
}
