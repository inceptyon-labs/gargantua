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
    /// The four file descriptors a stdout/stderr pipe pair contributes to a
    /// spawn — both write ends (which become the child's stdout/stderr after
    /// dup2) and both read ends (which the child must not inherit).
    private struct SpawnPipes {
        let outWrite: Int32
        let errWrite: Int32
        let outRead: Int32
        let errRead: Int32

        init(stdout: Pipe, stderr: Pipe) {
            self.outWrite = stdout.fileHandleForWriting.fileDescriptor
            self.errWrite = stderr.fileHandleForWriting.fileDescriptor
            self.outRead = stdout.fileHandleForReading.fileDescriptor
            self.errRead = stderr.fileHandleForReading.fileDescriptor
        }
    }

    /// Spawn `executable` with `arguments`, redirecting stdout and stderr to
    /// the write ends of the given pipes. The child is placed in a new
    /// process group whose pgid equals its pid (it becomes the group leader).
    ///
    /// - Precondition: `executable` must be an absolute path. This helper uses
    ///   `posix_spawn`, not `posix_spawnp`, so it does not search PATH.
    /// - The child inherits the parent's full environment and stdin fd.
    /// - The pipe fds (both read and write ends for stdout and stderr) are
    ///   closed in the child after the dup2s, so the child never holds extra
    ///   copies that would delay EOF on the parent side — except when a pipe
    ///   fd already aliases the target stdio fd (1 or 2), in which case we
    ///   skip the close to avoid closing our own redirected stdio.
    static func spawnInNewProcessGroup(
        executable: URL,
        arguments: [String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        let faInit = posix_spawn_file_actions_init(&fileActions)
        guard faInit == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: faInit)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attrs: posix_spawnattr_t?
        let attrInit = posix_spawnattr_init(&attrs)
        guard attrInit == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: attrInit)
        }
        defer { posix_spawnattr_destroy(&attrs) }

        let pipes = SpawnPipes(stdout: stdoutPipe, stderr: stderrPipe)
        try configureFileActions(&fileActions, pipes: pipes)
        try configureSpawnAttributes(&attrs)

        var argv = try buildCStringArray([executable.path] + arguments)
        defer { freeCStringArray(argv) }
        var envp = try buildCStringArray(
            ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        )
        defer { freeCStringArray(envp) }

        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuf in
            envp.withUnsafeMutableBufferPointer { envpBuf in
                posix_spawn(
                    &pid,
                    executable.path,
                    &fileActions,
                    &attrs,
                    argvBuf.baseAddress,
                    envpBuf.baseAddress,
                )
            }
        }

        guard result == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: result)
        }
        return pid
    }

    /// Redirect the child's stdout/stderr to the pipe write ends, then close
    /// the source pipe fds in the child so it doesn't hold extra copies that
    /// would delay EOF on the parent side. Skip `addclose(fd)` when `fd`
    /// aliases the stdio slot we just dup2'd into (e.g. parent had fd 1
    /// closed and Pipe() reused it) — otherwise we'd close our own
    /// redirected stdout/stderr.
    private static func configureFileActions(
        _ fileActions: inout posix_spawn_file_actions_t?,
        pipes: SpawnPipes
    ) throws {
        try check(posix_spawn_file_actions_adddup2(&fileActions, pipes.outWrite, 1))
        try check(posix_spawn_file_actions_adddup2(&fileActions, pipes.errWrite, 2))

        for fd in [pipes.outWrite, pipes.errWrite, pipes.outRead, pipes.errRead] where fd != 1 && fd != 2 {
            try check(posix_spawn_file_actions_addclose(&fileActions, fd))
        }
    }

    /// POSIX_SPAWN_SETPGROUP + pgroup=0 makes the child its own pgroup
    /// leader atomically, before the exec'd program runs. This is the
    /// whole point of this helper.
    private static func configureSpawnAttributes(_ attrs: inout posix_spawnattr_t?) throws {
        try check(posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attrs, 0))
    }

    /// Build a NULL-terminated argv/envp array from a Swift string array.
    /// strdup can return NULL on ENOMEM; a NULL in the middle of argv would
    /// make posix_spawn treat it as end-of-array, silently truncating —
    /// fail cleanly instead, freeing any partial allocations first.
    /// Caller owns the result and must free it via `freeCStringArray`.
    private static func buildCStringArray(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let dup = strdup(string) else {
                freeCStringArray(result)
                throw ProcessSpawnerError.spawnFailed(errno: ENOMEM)
            }
            result.append(dup)
        }
        result.append(nil)
        return result
    }

    private static func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for pointer in array { if let pointer { free(pointer) } }
    }

    /// Translate a non-zero POSIX return value into a thrown spawn error.
    /// The `posix_spawn_*` setup APIs return errno-style codes directly
    /// rather than setting `errno`, so callers must capture the return.
    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: result)
        }
    }
}
