import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Reads the live process table.
///
/// The snapshot comes from `sysctl(KERN_PROC_ALL)`, which an unprivileged
/// caller can read for every process. `proc_pidinfo(PROC_PIDTBSDINFO)`
/// is not enough here: it fails for setuid-root processes such as the
/// `login` wrapper terminals put between their server and the shell, and
/// a missing middle link would sever the ancestry walk from a terminal
/// to the agents it hosts. Working directories come from
/// `PROC_PIDVNODEPATHINFO`, which only needs to succeed for the current
/// user's own agent processes.
public struct LibprocProcessTable: ProcessTableProviding {

    public init() {}

    public func snapshot() -> [ProcessTableRecord] {
        #if canImport(Darwin)
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]

            // The table can grow between the size probe and the read, so
            // add headroom and retry a few times on ENOMEM.
            for _ in 0..<4 {
                var size = 0
                guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0
                else { return [] }
                size += size / 4

                var buffer = [UInt8](repeating: 0, count: size)
                let status = buffer.withUnsafeMutableBytes { bytes in
                    sysctl(
                        &mib, 4, bytes.baseAddress, &size, nil, 0)
                }
                guard status == 0 else {
                    if errno == ENOMEM { continue }
                    return []
                }

                let stride = MemoryLayout<kinfo_proc>.stride
                let count = size / stride
                var records: [ProcessTableRecord] = []
                records.reserveCapacity(count)
                buffer.withUnsafeBytes { bytes in
                    for index in 0..<count {
                        let info = bytes.loadUnaligned(
                            fromByteOffset: index * stride,
                            as: kinfo_proc.self)
                        let pid = info.kp_proc.p_pid
                        guard pid > 0 else { continue }
                        var comm = info.kp_proc.p_comm
                        let name = withUnsafeBytes(of: &comm) { commBytes in
                            String(
                                decoding: commBytes.prefix(while: { $0 != 0 }),
                                as: UTF8.self)
                        }
                        let tty = info.kp_eproc.e_tdev
                        records.append(
                            ProcessTableRecord(
                                pid: pid,
                                parentPid: info.kp_eproc.e_ppid,
                                name: name,
                                ttyDevice: tty == -1 ? nil : tty))
                    }
                }
                return records
            }
            return []
        #else
            return []
        #endif
    }

    public func currentWorkingDirectory(of pid: Int32) -> String? {
        #if canImport(Darwin)
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size
            else { return nil }
            let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return path.isEmpty ? nil : path
        #else
            return nil
        #endif
    }
}
