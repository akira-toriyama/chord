import Foundation

/// Build a `sockaddr_un` for an AF_UNIX filesystem path, returning the
/// address plus its serialized length for a `connect` / `bind` syscall.
/// Returns nil only when `path` exceeds `sun_path` capacity (~104 bytes
/// on macOS) — the single shared failure mode of both socket call sites
/// ([Control.query] client-side `connect`, [queryBindListen]
/// server-side `bind`).
///
/// Deliberately does NOT own the fd or perform the syscall: those are
/// the parts the two call sites legitimately differ on (Control closes
/// its fd via `defer`; `queryBindListen` closes explicitly, and one
/// connects while the other binds). The caller runs its own cleanup on
/// a nil return and performs the `connect` / `bind` itself.
func makeUnixSocketAddr(path: String) -> (addr: sockaddr_un, len: socklen_t)? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = path.utf8CString   // includes the trailing NUL
    guard pathBytes.count <= cap else { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: src.count)
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return (addr, len)
}
