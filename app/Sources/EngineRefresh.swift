import Foundation

/// Refresh: rediscover windows by restarting the same engine while keeping its saved session.
/// Backs up `State/` before and after the stop under `Backups/Refresh/<timestamp>/`
/// (`state-before`, `state-stopped`, `state-after.json`), restarts through `EngineControl`, and
/// waits for the session restore. Apps stay open; geometry may briefly change.
/// `result.message` is one plain sentence for the window map; the same line ends `refresh.log`.
struct RefreshResult: Equatable {
    var success: Bool
    var message: String
    var backup: URL?
}

final class EngineRefresh {
    let engine: EngineControlling
    let state: URL, backups: URL, lock: URL, log: URL
    var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var timestamp: () -> String = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
    /// Polls for the restored state: `statePolls` x `pollInterval`; then the engine's own session-restore grace.
    var statePolls = 40, pollInterval = 0.2, restoreGrace = 3.0

    init(engine: EngineControlling,
         state: URL = MicrofishPaths.state, backups: URL = MicrofishPaths.refreshBackups,
         lock: URL = MicrofishPaths.refreshLock, log: URL = MicrofishPaths.refreshLog) {
        self.engine = engine; self.state = state; self.backups = backups; self.lock = lock; self.log = log
    }

    static let alreadyRunning = "Window tracking is already restarting."
    static let didNotRestart = "Microfish didn’t restart in time. Open Microfish to try again. Your saved layout is backed up."
    static let didNotStop = "Microfish didn’t stop. Try again. Your saved layout is backed up."
    static let needsApproval = "Allow Microfish in System Settings > General > Login Items & Extensions, then try again."
    static let noBackup = "Couldn’t back up your layout, so nothing was restarted. Try again."

    private func note(_ line: String) {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func run() -> RefreshResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            return RefreshResult(success: false, message: Self.alreadyRunning, backup: nil)   // the running refresh owns the log
        }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: log.path, contents: nil)   // a fresh log per run: the map reads its last line
        let finish = { (result: RefreshResult) -> RefreshResult in self.note(result.message); return result }

        let backup = backups.appendingPathComponent(timestamp(), isDirectory: true)
        do {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            try copyState(to: backup.appendingPathComponent("state-before"))
        } catch {
            return finish(RefreshResult(success: false, message: Self.noBackup, backup: nil))
        }
        note("backup: \(backup.path)")

        let stopped = engine.stop()
        note("stop: \(stopped)")
        guard stopped.helperMayExit else { return finish(RefreshResult(success: false, message: Self.didNotStop, backup: backup)) }
        do { try copyState(to: backup.appendingPathComponent("state-stopped")) }
        catch { return finish(RefreshResult(success: false, message: Self.noBackup, backup: backup)) }

        let started = engine.start()
        note("start: \(started)")
        guard started.isRunning else {
            return finish(RefreshResult(success: false, message: started == .requiresApproval ? Self.needsApproval : Self.didNotRestart, backup: backup))
        }
        for _ in 0..<statePolls {
            if engine.queryState(timeout: 2) != nil {
                // Allow the engine's two-second session-restore grace period to finish.
                sleep(restoreGrace)
                guard let after = engine.queryState(timeout: 2) else { break }
                try? after.write(to: backup.appendingPathComponent("state-after.json"), atomically: true, encoding: .utf8)
                return finish(RefreshResult(success: true, message: "Windows refreshed; session backup: \(backup.path)", backup: backup))
            }
            sleep(pollInterval)
        }
        return finish(RefreshResult(success: false, message: Self.didNotRestart, backup: backup))
    }

    /// A copy of the whole `State/` folder (created empty when the engine has not saved yet).
    private func copyState(to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: state.path) { try fm.copyItem(at: state, to: destination) }
        else { try fm.createDirectory(at: destination, withIntermediateDirectories: true) }
    }
}
