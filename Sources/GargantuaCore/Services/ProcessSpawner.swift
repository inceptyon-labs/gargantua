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

        let outWriteFd = stdoutPipe.fileHandleForWriting.fileDescriptor
        let errWriteFd = stderrPipe.fileHandleForWriting.fileDescriptor
        let outReadFd = stdoutPipe.fileHandleForReading.fileDescriptor
        let errReadFd = stderrPipe.fileHandleForReading.fileDescriptor

        // Redirect child's stdout/stderr to pipe write ends. Guard each
        // posix_spawn_* return value: ignoring them lets a failed file_action
        // silently drop out of the list, which would leave the child with
        // undirected stdio while posix_spawn still reports success.
        try check(posix_spawn_file_actions_adddup2(&fileActions, outWriteFd, 1))
        try check(posix_spawn_file_actions_adddup2(&fileActions, errWriteFd, 2))

        // Close the source pipe fds in the child. dup2 leaves the source fd
        // open, and the read ends are only useful to the parent. Critical:
        // skip `addclose(fd)` when `fd` aliases the stdio slot we just
        // dup2'd into (e.g. parent had fd 1 closed and Pipe() reused it) —
        // otherwise we'd close our own redirected stdout/stderr.
        if outWriteFd != 1 && outWriteFd != 2 {
            try check(posix_spawn_file_actions_addclose(&fileActions, outWriteFd))
        }
        if errWriteFd != 1 && errWriteFd != 2 {
            try check(posix_spawn_file_actions_addclose(&fileActions, errWriteFd))
        }
        if outReadFd != 1 && outReadFd != 2 {
            try check(posix_spawn_file_actions_addclose(&fileActions, outReadFd))
        }
        if errReadFd != 1 && errReadFd != 2 {
            try check(posix_spawn_file_actions_addclose(&fileActions, errReadFd))
        }

        var attrs: posix_spawnattr_t?
        let attrInit = posix_spawnattr_init(&attrs)
        guard attrInit == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: attrInit)
        }
        defer { posix_spawnattr_destroy(&attrs) }

        // POSIX_SPAWN_SETPGROUP + pgroup=0 makes the child its own pgroup
        // leader atomically, before the exec'd program runs. This is the
        // whole point of this helper.
        try check(posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attrs, 0))

        // Build argv: [executable.path, args..., NULL]. strdup can return
        // NULL on ENOMEM; a NULL in the middle of argv would make posix_spawn
        // treat it as end-of-array, silently truncating arguments — fail
        // cleanly instead.
        let argvStrings = [executable.path] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = []
        argv.reserveCapacity(argvStrings.count + 1)
        for s in argvStrings {
            guard let dup = strdup(s) else {
                argv.forEach { if let p = $0 { free(p) } }
                throw ProcessSpawnerError.spawnFailed(errno: ENOMEM)
            }
            argv.append(dup)
        }
        argv.append(nil)
        defer { argv.forEach { if let p = $0 { free(p) } } }

        // Build envp from the parent's environment, same NULL-guard pattern.
        let envStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = []
        envp.reserveCapacity(envStrings.count + 1)
        for s in envStrings {
            guard let dup = strdup(s) else {
                envp.forEach { if let p = $0 { free(p) } }
                throw ProcessSpawnerError.spawnFailed(errno: ENOMEM)
            }
            envp.append(dup)
        }
        envp.append(nil)
        defer { envp.forEach { if let p = $0 { free(p) } } }

        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuf in
            envp.withUnsafeMutableBufferPointer { envpBuf in
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

    /// Translate a non-zero POSIX return value into a thrown spawn error.
    /// The `posix_spawn_*` setup APIs return errno-style codes directly
    /// rather than setting `errno`, so callers must capture the return.
    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw ProcessSpawnerError.spawnFailed(errno: result)
        }
    }
}
