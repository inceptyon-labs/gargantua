import Darwin
import Foundation

/// Error thrown when `posix_spawn` fails before the child can exec.
enum ProcessSpawnerError: Error, Equatable {
    case spawnFailed(errno: Int32)
}

/// Thin wrapper around `posix_spawn` that atomically places the child in its
/// own process group before exec, via `POSIX_SPAWN_SETPGROUP` with pgroup=0.
///
/// Why this primitive exists: the previous approach called `setpgid(pid, 0)`
/// on the child from the parent after `Process.run()`. That is racy — if the
/// child forks descendants before the parent's `setpgid` call executes, those
/// descendants inherit the parent's process group rather than the child's,
/// and our timeout/escalation path can't signal them as a group.
/// `posix_spawn` with `POSIX_SPAWN_SETPGROUP` closes that gap because the
/// kernel sets the new pgroup in the child *before* the child ever runs user
/// code, so the guarantee holds for every descendant.
enum ProcessSpawner {
    /// Spawn `executable` with `arguments`, redirecting stdout and stderr to
    /// the write ends of the given pipes. The child is placed in a new
    /// process group whose pgid equals its pid (it becomes the group leader).
    ///
    /// - Precondition: `executable` must be an absolute path. This helper uses
    ///   `posix_spawn`, not `posix_spawnp`, so it does not search PATH.
    /// - The child inherits the parent's full environment and stdin fd.
    /// - The four pipe fds (both read and write ends for stdout and stderr)
    ///   are closed in the child after the dup2s, so the child never holds
    ///   extra copies that would delay EOF on the parent side.
    static func spawnInNewProcessGroup(
        executable: URL,
        arguments: [String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: errno)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let outWriteFd = stdoutPipe.fileHandleForWriting.fileDescriptor
        let errWriteFd = stderrPipe.fileHandleForWriting.fileDescriptor
        let outReadFd = stdoutPipe.fileHandleForReading.fileDescriptor
        let errReadFd = stderrPipe.fileHandleForReading.fileDescriptor

        // Redirect child's stdout/stderr to pipe write ends.
        posix_spawn_file_actions_adddup2(&fileActions, outWriteFd, 1)
        posix_spawn_file_actions_adddup2(&fileActions, errWriteFd, 2)
        // Close the original pipe fds in the child. dup2 leaves the source
        // fd open, and the read ends are only useful to the parent.
        posix_spawn_file_actions_addclose(&fileActions, outWriteFd)
        posix_spawn_file_actions_addclose(&fileActions, errWriteFd)
        posix_spawn_file_actions_addclose(&fileActions, outReadFd)
        posix_spawn_file_actions_addclose(&fileActions, errReadFd)

        var attrs: posix_spawnattr_t?
        guard posix_spawnattr_init(&attrs) == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: errno)
        }
        defer { posix_spawnattr_destroy(&attrs) }

        // POSIX_SPAWN_SETPGROUP + pgroup=0 makes the child its own pgroup
        // leader atomically, before the exec'd program runs. This is the
        // whole point of this helper.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)

        // Build argv: [executable.path, args..., NULL].
        let argvStrings = [executable.path] + arguments
        let argv = argvStrings.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var argvPtrs: [UnsafeMutablePointer<CChar>?] = argv.map { $0 }
        argvPtrs.append(nil)

        // Build envp from the parent's environment.
        let envStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let envp = envStrings.map { strdup($0) }
        defer { envp.forEach { free($0) } }
        var envpPtrs: [UnsafeMutablePointer<CChar>?] = envp.map { $0 }
        envpPtrs.append(nil)

        var pid: pid_t = 0
        let result = argvPtrs.withUnsafeMutableBufferPointer { argvBuf in
            envpPtrs.withUnsafeMutableBufferPointer { envpBuf in
                posix_spawn(
                    &pid,
                    executable.path,
                    &fileActions,
                    &attrs,
                    argvBuf.baseAddress,
                    envpBuf.baseAddress
                )
            }
        }

        guard result == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: result)
        }
        return pid
    }
}
