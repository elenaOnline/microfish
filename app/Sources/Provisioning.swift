import Foundation

/// First-run and every-run setup of the user's data. Copies each file in the bundle's `Defaults/`
/// that the user does not have yet, and creates the folders the engine and helper write to.
/// An existing file is never touched, whatever it contains.
enum MicrofishProvisioning {
    /// What the contract says a complete `Defaults/` holds; a missing one is logged, not fatal.
    static let expectedDefaults = ["preferences.json", "init.lua", "settings.lua", "shortcuts.lua"]

    struct Report: Equatable {
        /// Names copied from `Defaults/` this run.
        var copied: [String] = []
        /// Names already present (left alone).
        var kept: [String] = []
        /// Expected defaults the bundle does not carry.
        var missingDefaults: [String] = []
        /// Folders or copies that failed, as readable lines.
        var problems: [String] = []
        /// The log lines for this run.
        var log: [String] { 
            var lines: [String] = []
            if !copied.isEmpty { lines.append("provisioned: " + copied.joined(separator: ", ")) }
            for name in missingDefaults { lines.append("Defaults/\(name) is missing from the app; skipped") }
            lines += problems
            return lines
        }
    }

    @discardableResult
    static func run(support: URL = MicrofishPaths.support,
                    state: URL = MicrofishPaths.state,
                    runtime: URL = MicrofishPaths.runtime,
                    logs: URL = MicrofishPaths.logs,
                    defaults: URL = MicrofishPaths.defaults,
                    fileManager fm: FileManager = .default) -> Report {
        var report = Report()
        for directory in [support, state, runtime, logs] {
            do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { report.problems.append("could not create \(directory.lastPathComponent): \(error.localizedDescription)") }
        }
        let bundled = (try? fm.contentsOfDirectory(at: defaults, includingPropertiesForKeys: [.isRegularFileKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent).sorted() ?? []
        report.missingDefaults = expectedDefaults.filter { !bundled.contains($0) }
        for name in bundled where !name.hasPrefix(".") {
            let destination = support.appendingPathComponent(name)
            // lstat, not fileExists: a dangling symlink the user made is still theirs.
            if (try? destination.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                report.kept.append(name); continue
            }
            do { try fm.copyItem(at: defaults.appendingPathComponent(name), to: destination); report.copied.append(name) }
            catch CocoaError.fileWriteFileExists { report.kept.append(name) }   // appeared since the check
            catch { report.problems.append("could not copy Defaults/\(name): \(error.localizedDescription)") }
        }
        for line in report.log { NSLog("Microfish provisioning: %@", line) }
        return report
    }
}
