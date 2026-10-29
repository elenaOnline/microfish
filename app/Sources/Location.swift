import AppKit

// Where Microfish is allowed to run, and whether it is the only copy running. The decisions are pure
// functions of facts the launch code gathers, so tests drive every case without a bundle on disk.
// Apple's own pattern is followed: an app opened from a disk image or from Gatekeeper's translocated copy
// is told to be moved, and it does not move itself (see notes/app-bundle.md for why).

enum InstallLocation {
    enum Problem: Equatable { case translocated, readOnlyVolume, outsideApplications }

    /// Developers running a build from `build/` set this to skip the location check (not the single-instance guard).
    static let overrideKey = "MICROFISH_ALLOW_ANY_LOCATION"
    static func overrideActive(_ environment: [String: String]) -> Bool { environment[overrideKey] == "1" }

    /// `/Applications` and `~/Applications`, the two places the Finder and Launchpad treat as installed.
    static func applicationRoots(home: String) -> [String] { ["/Applications", (home as NSString).appendingPathComponent("Applications")] }

    /// What is wrong with running from `bundlePath`, or nil when it is fine. The first matching reason wins:
    /// translocation and a read-only volume say more than "outside Applications" (and both are outside it anyway).
    static func problem(bundlePath: String, isTranslocated: Bool, isReadOnlyVolume: Bool, applicationRoots: [String]) -> Problem? {
        if isTranslocated || isTranslocatedPath(bundlePath) { return .translocated }
        if isReadOnlyVolume { return .readOnlyVolume }
        let path = canonical(bundlePath)
        for root in applicationRoots {
            let r = canonical(root)
            if path.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return nil }
        }
        return .outsideApplications
    }

    /// Gatekeeper's randomized read-only mount: `/private/var/folders/…/AppTranslocation/<UUID>/d/Microfish.app`.
    static func isTranslocatedPath(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Asks Security.framework, which knows even when the path looks ordinary. The symbol is private-ish but exported
    /// and long stable (Sparkle and LetsMove use it); if it is missing the path check above still catches the usual case.
    static func systemSaysTranslocated(_ url: URL) -> Bool {
        typealias Probe = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        _ = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "SecTranslocateIsTranslocatedURL") else { return false }
        let probe = unsafeBitCast(symbol, to: Probe.self)
        var result = false
        return probe(url as CFURL, &result, nil) && result
    }

    static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        // Both: the resource key misses the sealed system volume, the mount flag is what `mount` reports.
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return true }
        var fs = statfs()
        return statfs(url.path, &fs) == 0 && fs.f_flags & UInt32(MNT_RDONLY) != 0
    }
}

/// The alert shown instead of starting. Pure data; `LaunchGate` presents it.
struct LocationAlert: Equatable {
    var title = "Move Microfish to the Applications folder"
    var message: String
    var openFolderTitle = "Open Applications Folder"
    var quitTitle = "Quit"

    static func forProblem(_ problem: InstallLocation.Problem) -> LocationAlert {
        switch problem {
        case .readOnlyVolume:
            return LocationAlert(message: "Microfish is running from a disk image; drag it into the Applications folder, eject the disk image, then open Microfish from Applications.")
        case .translocated:
            return LocationAlert(message: "macOS is running Microfish from a temporary read-only copy; drag Microfish into the Applications folder, then open it from there.")
        case .outsideApplications:
            return LocationAlert(message: "Microfish keeps itself updated and starts at login only from the Applications folder; move it there, then open it again.")
        }
    }
}

struct RunningInstance: Equatable {
    var pid: Int32
    var launchDate: Date?
}

enum SingleInstance {
    /// The other Microfish that outranks `me` (launched earlier; equal or unknown dates: the lower pid), or nil when `me` is the
    /// one to keep running. Two copies started in the same instant therefore never both quit.
    static func survivor(me: RunningInstance, others: [RunningInstance]) -> RunningInstance? {
        func outranks(_ a: RunningInstance, _ b: RunningInstance) -> Bool {
            switch (a.launchDate, b.launchDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.pid < b.pid
            }
        }
        return others.filter { $0.pid != me.pid && outranks($0, me) }.min { outranks($0, $1) }
    }
}

#if !NAVIGATOR_TESTS
/// Runs first thing at launch. `proceed()` false = this process must quit now without starting anything:
/// no provisioning, no agent registration, no engine, no updater.
enum LaunchGate {
    @MainActor static func proceed() -> Bool {
        let bundle = Bundle.main
        // A bare executable (dev run, tests) is not an installed app: nothing to check.
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier == MicrofishPaths.appIdentifier else { return true }
        if yieldToExistingInstance() { return false }
        let env = ProcessInfo.processInfo.environment
        if InstallLocation.overrideActive(env) { return true }
        let url = bundle.bundleURL
        guard let problem = InstallLocation.problem(
            bundlePath: url.path,
            isTranslocated: InstallLocation.systemSaysTranslocated(url),
            isReadOnlyVolume: InstallLocation.isOnReadOnlyVolume(url),
            applicationRoots: InstallLocation.applicationRoots(home: NSHomeDirectory())) else { return true }
        let alert = LocationAlert.forProblem(problem)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSAlert()
        panel.messageText = alert.title; panel.informativeText = alert.message
        panel.addButton(withTitle: alert.openFolderTitle)
        panel.addButton(withTitle: alert.quitTitle)
        if panel.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true)) }
        NSLog("Navigator launch: not starting, running from %@ (%@)", url.path, String(describing: problem))
        return false
    }

    /// Another Microfish is running: bring it forward (a reopen opens its Settings) and let this one go.
    @MainActor private static func yieldToExistingInstance() -> Bool {
        let me = NSRunningApplication.current
        let all = NSRunningApplication.runningApplications(withBundleIdentifier: MicrofishPaths.appIdentifier)
        func instance(_ app: NSRunningApplication) -> RunningInstance { RunningInstance(pid: app.processIdentifier, launchDate: app.launchDate) }
        guard let winner = SingleInstance.survivor(me: instance(me), others: all.filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }.map(instance)),
              let other = all.first(where: { $0.processIdentifier == winner.pid }) else { return false }
        NSLog("Navigator launch: another Microfish is running (pid %d); handing over", winner.pid)
        if let url = other.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            // Wait (briefly) for LaunchServices to take the request; this process is about to terminate.
            let sent = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in sent.signal() }
            _ = sent.wait(timeout: .now() + 2)
        } else { other.activate() }
        return true
    }
}
#endif
