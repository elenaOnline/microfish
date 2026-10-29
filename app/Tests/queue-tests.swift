// Headless tests and measurement for CommandRunner (the helper's bridge command queue). Appended after
// src/main.swift (NAVIGATOR_TESTS). The "bridge" is a shell script in a temp dir; nothing touches the real engine.
import Darwin
do {
 var n = 0
 func ok(_ c: @autoclosure () -> Bool, _ m: String) { precondition(c(), "queue: " + m); n += 1 }
 func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
 func pump(until cond: () -> Bool, limit: Double = 30) { let end = Date(timeIntervalSinceNow: limit); while !cond() && Date() < end { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002)) } }
 let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-queue-\(getpid())")
 try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 defer { try? FileManager.default.removeItem(at: dir) }
 let log = dir.appendingPathComponent("log.txt")
 func script(_ name: String, _ body: String) -> URL {
  let u = dir.appendingPathComponent(name)
  try! "#!/bin/sh\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
  chmod(u.path, 0o755); return u
 }
 // Records start/end per command; argument "slow" sleeps longer so only serialization keeps the order.
 let fake = script("fake", """
 echo "start $1" >> '\(log.path)'
 case "$1" in slow*) sleep 0.06 ;; *) sleep 0.005 ;; esac
 case "$1" in fail*) echo "boom $1" >&2; echo "end $1" >> '\(log.path)'; exit 3 ;; esac
 echo "end $1" >> '\(log.path)'
 """)
 let queue = DispatchQueue(label: "test.commands", qos: .userInitiated)

 // Order, no overlap, outcomes.
 do {
  let runner = CommandRunner(executable: fake, queue: queue)
  var done: [(String, CommandRunner.Outcome)] = []
  let lock = NSLock()
  let names = ["a1", "slow2", "a3", "fail4", "slow5", "a6", "a7", "a8", "a9", "slow10", "a11", "a12"]
  for name in names { runner.submit([name]) { o in lock.lock(); done.append((name, o)); lock.unlock() } }
  pump { lock.lock(); defer { lock.unlock() }; return done.count == names.count }
  ok(done.map { $0.0 } == names, "completions arrive in submission order: \(done.map { $0.0 })")
  let lines = try! String(contentsOf: log).split(separator: "\n").map(String.init)
  ok(lines == names.flatMap { ["start \($0)", "end \($0)"] }, "the bridge ran one at a time, in order: \(lines)")
  ok(done.first { $0.0 == "fail4" }!.1.status == 3 && done.first { $0.0 == "fail4" }!.1.diagnostic == "boom fail4\n", "status and stderr reported")
  ok(done.filter { $0.1.status == 0 }.count == names.count - 1 && done.allSatisfy { $0.1.launchError == nil }, "others succeeded")
  try? FileManager.default.removeItem(at: log)
 }
 // Submissions from several threads at once: each thread's own commands keep their order, and none are lost or doubled.
 do {
  let runner = CommandRunner(executable: fake, queue: queue)
  let lock = NSLock(); var count = 0; var order: [String] = []
  let group = DispatchGroup()
  for t in 0..<4 { DispatchQueue.global().async(group: group) { for i in 0..<5 { runner.submit(["t\(t)-\(i)"]) { _ in lock.lock(); count += 1; lock.unlock() } } } }
  group.wait()
  pump { lock.lock(); defer { lock.unlock() }; return count == 20 }
  let started = try! String(contentsOf: log).split(separator: "\n").filter { $0.hasPrefix("start") }.map { String($0.dropFirst(6)) }
  ok(started.count == 20 && Set(started).count == 20, "20 concurrent submissions run exactly once each")
  for t in 0..<4 { order = started.filter { $0.hasPrefix("t\(t)-") }; ok(order == (0..<5).map { "t\(t)-\($0)" }, "thread \(t) order kept") }
  try? FileManager.default.removeItem(at: log)
 }
 // The queue is free while a command runs (the old design parked a thread in waitUntilExit).
 do {
  let sleeper = script("sleeper", "sleep 0.4")
  let runner = CommandRunner(executable: sleeper, queue: queue)
  var finishedAt = 0.0; let t0 = now()
  runner.submit(["x"]) { _ in finishedAt = now() }
  var markerAt = 0.0
  Thread.sleep(forTimeInterval: 0.05)
  queue.async { markerAt = now() }
  pump { markerAt != 0 }
  ok(markerAt - t0 < 200, "serial queue stays available while the bridge runs (\(markerAt - t0) ms)")
  ok(finishedAt == 0, "command still running at that moment")
  pump { finishedAt != 0 }
  ok(finishedAt - t0 >= 380, "completion waits for the process (\(finishedAt - t0) ms)")
 }
 // Large stderr must not deadlock; a launch failure is reported and the queue goes on.
 do {
  let noisy = script("noisy", "head -c 300000 /dev/zero | tr '\\0' 'e' >&2; exit 1")
  let runner = CommandRunner(executable: noisy, queue: queue)
  var big: CommandRunner.Outcome?
  runner.submit(["x"]) { big = $0 }
  pump { big != nil }
  ok(big?.status == 1 && big?.diagnostic.utf8.count == 300000, "300 KB of stderr read in full (\(big?.diagnostic.utf8.count ?? -1) bytes)")
  let missing = CommandRunner(executable: dir.appendingPathComponent("nope"), queue: queue)
  var results: [CommandRunner.Outcome] = []
  for _ in 0..<3 { missing.submit(["x"]) { results.append($0) } }
  pump { results.count == 3 }
  ok(results.allSatisfy { $0.launchError != nil && $0.status != 0 }, "launch failures reported, queue not wedged")
 }
 // A descendant that keeps stderr open must not stall the queue past the grace period.
 do {
  let leaky = script("leaky", "sleep 1.2 &\nexit 0")
  let runner = CommandRunner(executable: leaky, queue: queue); runner.eofGrace = 0.1
  var firstAt = 0.0, secondAt = 0.0; let t0 = now()
  runner.submit(["x"]) { _ in firstAt = now() }
  runner.submit(["y"]) { _ in secondAt = now() }
  pump { secondAt != 0 }
  ok(firstAt - t0 < 600 && secondAt - t0 < 1000, "stderr held by a grandchild does not hold the queue (\(firstAt - t0), \(secondAt - t0) ms)")
 }
 // End to end through Navigator.sendCommand: the bridge is MicrofishPaths.bridgeExecutable (MICROFISH_BRIDGE); completion runs on main.
 do {
  let nav = Navigator(path: dir.appendingPathComponent("navigator.tsv").path)
  ok(nav.commandRunner.executable == MicrofishPaths.bridgeExecutable, "the bridge comes from MicrofishPaths")
  nav.commandRunner = CommandRunner(executable: fake, queue: nav.commandQueue)
  var accepted: [(Bool, Bool)] = []
  for name in ["a1", "slow2", "a3"] { nav.sendCommand([name]) { accepted.append(($0, Thread.isMainThread)) } }
  pump { accepted.count == 3 }
  ok(accepted.count == 3 && accepted.allSatisfy { $0.0 && $0.1 }, "sendCommand completions are accepted and on main: \(accepted)")
  let lines = try! String(contentsOf: log).split(separator: "\n").map(String.init)
  ok(lines == ["start a1", "end a1", "start slow2", "end slow2", "start a3", "end a3"], "sendCommand keeps order: \(lines)")
  try? FileManager.default.removeItem(at: log)
 }

 // Measurement. N sequential commands of a 5 ms bridge. Wall time per command minus the bridge's own cost, compared with
 // a posix_spawn + waitpid floor and with the pre-change algorithm (replicated from ef3b967 sendCommand: run, read stderr to EOF, waitUntilExit).
 do {
  // Three bridges: a 5 ms sleeper (the brief's fake), a script that exits at once, and /usr/bin/true (the bridge-shaped fast exit
  // focus-latency-report.md measured the ~65 ms waitUntilExit lag with).
  let N = 100
  func report(_ label: String, _ ms: Double) { print(String(format: "  queue bench %-34@ %7.1f ms total, %6.2f ms per command", label as NSString, ms, ms / Double(N))) }
  for (name, bench) in [("5 ms sleeper script", script("bench", "sleep 0.005")), ("instant-exit script", script("instant", "exit 0")), ("/usr/bin/true", URL(fileURLWithPath: "/usr/bin/true"))] {
   func legacy() -> (Double, [Double]) {
    var per: [Double] = []; let plock = NSLock()
    let q = DispatchQueue(label: "legacy", qos: .userInitiated); var finished = false
    let t0 = now()
    for i in 0..<N {
     q.async {
      let ts = now()
      let c = Process(); c.executableURL = bench; c.arguments = ["\(i)"]; c.standardOutput = FileHandle.nullDevice
      let e = Pipe(); c.standardError = e
      try! c.run(); _ = e.fileHandleForReading.readDataToEndOfFile(); c.waitUntilExit(); _ = c.terminationStatus
      plock.lock(); per.append(now() - ts); plock.unlock()
      if i == N - 1 { DispatchQueue.main.async { finished = true } }
     }
    }
    pump { finished }; return (now() - t0, per)
   }
   func current() -> (Double, [Double]) {
    var stamps: [Double] = []
    let runner = CommandRunner(executable: bench, queue: DispatchQueue(label: "new", qos: .userInitiated))
    var done = 0; let lock = NSLock(); let t0 = now()
    for i in 0..<N { runner.submit(["\(i)"]) { _ in lock.lock(); done += 1; stamps.append(now()); lock.unlock() } }
    pump { lock.lock(); defer { lock.unlock() }; return done == N }
    let gaps = zip([t0] + stamps, stamps).map { $1 - $0 }
    return (now() - t0, gaps)
   }
   func floor() -> Double {
    let t0 = now()
    for i in 0..<N {
     var pid: pid_t = 0; var devnull: posix_spawn_file_actions_t? = nil; posix_spawn_file_actions_init(&devnull)
     posix_spawn_file_actions_addopen(&devnull, 1, "/dev/null", O_WRONLY, 0); posix_spawn_file_actions_addopen(&devnull, 2, "/dev/null", O_WRONLY, 0)
     let argv: [UnsafeMutablePointer<CChar>?] = [strdup(bench.path), strdup("\(i)"), nil]
     posix_spawn(&pid, bench.path, &devnull, nil, argv, environ)
     var st: Int32 = 0; waitpid(pid, &st, 0)
     posix_spawn_file_actions_destroy(&devnull); argv.forEach { free($0) }
    }
    return now() - t0
   }
   _ = floor()   // warm the page cache
   let f = floor(), (l, lper) = legacy(), (c, cper) = current()
   print("  bridge: \(name)")
   report("floor (posix_spawn + waitpid)", f); report("before (waitUntilExit, ef3b967)", l); report("after (terminationHandler)", c)
   print(String(format: "  overhead over floor: before %.1f ms, after %.1f ms per command", (l - f) / Double(N), (c - f) / Double(N)))
   func stat(_ x: [Double]) -> String { let y = x.sorted(); return String(format: "p50 %.1f p90 %.1f max %.1f, %d over 30 ms", y[y.count/2], y[Int(Double(y.count)*0.9)], y.last!, y.filter { $0 > 30 }.count) }
   print("  per-command ms, before: \(stat(lper))"); print("  per-command ms, after:  \(stat(cper))")
  }
  // Timing is reported, never asserted: machine load would make it flaky.
 }
 print("Command queue checks passed: \(n)")
}
