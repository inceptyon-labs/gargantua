import Foundation

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is deleted when this delegate call
        // returns, so either move it synchronously or copy out the bytes we
        // need before hopping actors. We move it to a sibling tmp path first,
        // then hand the URL off to the main actor for SHA verification.
        let tmpDir = FileManager.default.temporaryDirectory
        let scratch = tmpDir.appendingPathComponent("gargantua-model-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: location, to: scratch)
        } catch {
            MainActor.assumeIsolated {
                self.failDownload("Failed to stage downloaded file: \(error.localizedDescription)")
            }
            return
        }

        MainActor.assumeIsolated {
            self.handleDownloadedFile(at: scratch)
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            self.handleProgress(currentFileBytes: totalBytesWritten)
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }

        MainActor.assumeIsolated {
            self.failDownload(error.localizedDescription)
        }
    }

    // MARK: Main-actor handlers

    private func handleProgress(currentFileBytes: Int64) {
        let total = modelInfo.expectedSize
        let bytesReceived = completedBytes + max(0, currentFileBytes)
        let progress = total > 0 ? Double(bytesReceived) / Double(total) : 0
        state = .downloading(progress: min(progress, 1.0), bytesReceived: bytesReceived)
    }

    private func handleDownloadedFile(at scratch: URL) {
        guard !didCancel else {
            try? FileManager.default.removeItem(at: scratch)
            return
        }
        guard currentFileIndex < modelInfo.files.count else {
            try? FileManager.default.removeItem(at: scratch)
            return
        }
        let file = modelInfo.files[currentFileIndex]
        let indexAtDispatch = currentFileIndex

        // Hashing a ~700 MB safetensors on the main actor freezes the UI
        // and blocks cancellation for seconds. Offload to a detached task;
        // the hash function is static and touches no actor state.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<String, Error> = Result {
                try Self.sha256Hex(of: scratch)
            }
            await self?.completeFileVerification(
                scratch: scratch,
                dispatchedIndex: indexAtDispatch,
                expectedFile: file,
                hashResult: result
            )
        }
    }

    private func completeFileVerification(
        scratch: URL,
        dispatchedIndex: Int,
        expectedFile: ModelFile,
        hashResult: Result<String, Error>
    ) {
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Cancel, or a new download run started while we were hashing —
        // drop this work on the floor instead of mutating state.
        guard !didCancel, dispatchedIndex == currentFileIndex else { return }

        let actualSha: String
        switch hashResult {
        case .success(let sha):
            actualSha = sha
        case .failure(let error):
            failDownload("Failed to hash \(expectedFile.name): \(error.localizedDescription)")
            return
        }
        guard actualSha == expectedFile.sha256 else {
            failDownload("Checksum mismatch for \(expectedFile.name): expected \(expectedFile.sha256), got \(actualSha).")
            return
        }

        let destination = modelDirectory.appendingPathComponent(expectedFile.name)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: scratch, to: destination)
        } catch {
            failDownload("Failed to stage \(expectedFile.name): \(error.localizedDescription)")
            return
        }

        completedBytes += expectedFile.size
        currentFileIndex += 1
        startNextFileDownload()
    }
}
