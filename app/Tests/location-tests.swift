// Headless tests for the launch gate's decisions (InstallLocation, LocationAlert, SingleInstance). Pure functions only:
// nothing is launched, no alert is shown, no bundle is needed.
import Foundation

var locationChecks = 0
func lcheck(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "location: " + m); locationChecks += 1 }

let home = "/Users/someone"
let roots = InstallLocation.applicationRoots(home: home)
func problem(_ path: String, translocated: Bool = false, readOnly: Bool = false) -> InstallLocation.Problem? {
    InstallLocation.problem(bundlePath: path, isTranslocated: translocated, isReadOnlyVolume: readOnly, applicationRoots: roots)
}

// MARK: where it may run
lcheck(roots == ["/Applications", "/Users/someone/Applications"], "the two application folders: \(roots)")
lcheck(problem("/Applications/Microfish.app") == nil, "/Applications is fine")
lcheck(problem("/Users/someone/Applications/Microfish.app") == nil, "~/Applications is fine")
lcheck(problem("/Applications/Utilities/Microfish.app") == nil, "a subfolder of Applications is fine")
lcheck(problem("/Users/someone/Applications/Tools/Microfish.app") == nil, "a subfolder of ~/Applications is fine")
lcheck(problem("/Users/someone/Downloads/Microfish.app") == .outsideApplications, "Downloads")
lcheck(problem("/Users/someone/Desktop/Microfish.app") == .outsideApplications, "Desktop")
lcheck(problem("/tmp/mf/build/Microfish.app") == .outsideApplications, "a build folder")
lcheck(problem("/Applications-old/Microfish.app") == .outsideApplications, "a sibling that merely starts with the same letters")
lcheck(problem("/Users/someone/Applicationsx/Microfish.app") == .outsideApplications, "same for ~/Applicationsx")
lcheck(problem("/Applications/../Users/someone/Downloads/Microfish.app") == .outsideApplications, "dot-dot does not smuggle a path in")
lcheck(problem("/Applications") == .outsideApplications, "the folder itself is not an app inside it")

// MARK: translocation and disk images
lcheck(problem("/private/var/folders/ab/cd1234/T/AppTranslocation/8E1F0C0A-1111-2222-3333-444455556666/d/Microfish.app") == .translocated, "translocated path")
lcheck(problem("/Applications/Microfish.app", translocated: true) == .translocated, "the system says translocated even for an ordinary-looking path")
lcheck(InstallLocation.isTranslocatedPath("/private/var/folders/x/AppTranslocation/U/d/Microfish.app") && !InstallLocation.isTranslocatedPath("/Applications/Microfish.app"), "path heuristic")
lcheck(problem("/Volumes/Microfish 1.0/Microfish.app", readOnly: true) == .readOnlyVolume, "a read-only disk image")
lcheck(problem("/Volumes/Microfish 1.0/Microfish.app") == .outsideApplications, "a writable volume outside Applications")
lcheck(problem("/Volumes/Microfish 1.0/Microfish.app", translocated: true, readOnly: true) == .translocated, "translocation outranks read-only")
lcheck(problem("/Applications/Microfish.app", readOnly: true) == .readOnlyVolume, "a read-only volume is a problem even under Applications")

// The real probes, on facts about this process: an ordinary executable is neither translocated nor on a read-only volume.
let me = URL(fileURLWithPath: CommandLine.arguments[0])
lcheck(!InstallLocation.systemSaysTranslocated(me), "this test binary is not translocated")
lcheck(!InstallLocation.isOnReadOnlyVolume(me), "this test binary is on a writable volume")
lcheck(InstallLocation.isOnReadOnlyVolume(URL(fileURLWithPath: "/System")), "the system volume is read-only")

// MARK: developer override
lcheck(InstallLocation.overrideActive(["MICROFISH_ALLOW_ANY_LOCATION": "1"]), "override on")
lcheck(!InstallLocation.overrideActive([:]) && !InstallLocation.overrideActive(["MICROFISH_ALLOW_ANY_LOCATION": "0"]) && !InstallLocation.overrideActive(["MICROFISH_ALLOW_ANY_LOCATION": ""]), "off unless exactly 1")

// MARK: alert
for kind in [InstallLocation.Problem.translocated, .readOnlyVolume, .outsideApplications] {
    let a = LocationAlert.forProblem(kind)
    lcheck(a.title == "Move Microfish to the Applications folder" && a.quitTitle == "Quit", "title and Quit button: \(kind)")
    lcheck(a.message.hasSuffix(".") && a.message.contains("Applications"), "one sentence naming the folder: \(kind)")
}
lcheck(LocationAlert.forProblem(.readOnlyVolume).message.contains("disk image") && LocationAlert.forProblem(.translocated).message.contains("temporary"), "the reason differs by cause")

// MARK: one instance
let t0 = Date(timeIntervalSince1970: 1_000_000)
func inst(_ pid: Int32, _ offset: Double?) -> RunningInstance { RunningInstance(pid: pid, launchDate: offset.map { t0.addingTimeInterval($0) }) }
lcheck(SingleInstance.survivor(me: inst(10, 0), others: []) == nil, "alone: carry on")
lcheck(SingleInstance.survivor(me: inst(10, 5), others: [inst(10, 5)]) == nil, "myself in the list does not count")
lcheck(SingleInstance.survivor(me: inst(20, 5), others: [inst(10, 0)]) == inst(10, 0), "an earlier instance wins: this one yields")
lcheck(SingleInstance.survivor(me: inst(10, 0), others: [inst(20, 5)]) == nil, "I am earlier: I stay")
lcheck(SingleInstance.survivor(me: inst(20, 5), others: [inst(30, 5), inst(10, 5)]) == inst(10, 5), "same instant: the lower pid wins")
lcheck(SingleInstance.survivor(me: inst(10, 5), others: [inst(20, 5)]) == nil, "same instant, lower pid stays")
lcheck(SingleInstance.survivor(me: inst(10, nil), others: [inst(20, 5)]) == inst(20, 5), "unknown launch date yields to a known one")
lcheck(SingleInstance.survivor(me: inst(30, nil), others: [inst(20, nil)]) == inst(20, nil), "both unknown: lower pid")
lcheck(SingleInstance.survivor(me: inst(30, 9), others: [inst(20, 5), inst(10, 2)]) == inst(10, 2), "of several, the earliest is named")
// Two copies starting together: exactly one of them continues.
let pair = [inst(11, 3), inst(12, 3)]
lcheck(pair.filter { me in SingleInstance.survivor(me: me, others: pair) == nil }.count == 1, "never both quit, never both stay")
print("location checks passed:", locationChecks)
