import AppKit

/// Records only after the engine has acknowledged suspension. The owner supplies
/// the engine lease; local event capture alone never suppresses global bindings.
final class ShortcutRecorder: NSObject {
    var suspend: ((@escaping (Result<() -> Void, Error>) -> Void) -> Void)?
    private var resume: (() -> Void)?
    var didFinish: ((String?, String?) -> Void)?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private(set) var isRecording = false
    private(set) var isStarting = false
    private var timer: Timer?
    func begin(window: NSWindow) {
        cancel()
        generation += 1
        let attempt = generation
        isStarting = true
        let center = NotificationCenter.default
        observers = [center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel() }, center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.cancel() }, center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.cancel() }]
        guard let suspend else { finish(nil, "Couldn’t start recording. Microfish isn’t responding."); return }
        suspend { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { if case .success(let release) = result { release() }; return }
                guard self.generation == attempt, self.isStarting else { if case .success(let release) = result { release() }; return }
                switch result {
                case .failure(let error): self.finish(nil, error.localizedDescription)
                case .success(let release):
                    self.resume = release
                    self.isStarting = false; self.isRecording = true
                    self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                        guard let self else { return event }
                        if event.keyCode == 53 { self.cancel(); return nil }
                        // Plain Delete clears the binding, as in System Settings' shortcut fields.
                        if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty { self.finish("", nil); return nil }
                        guard let chord = Self.chord(event) else { return nil }
                        self.finish(chord, nil); return nil
                    }
                    self.timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.finish(nil, "Recording timed out.") }
                }
            }
        }
    }
    func cancel() { if isStarting || isRecording { finish(nil, nil) } }
    private func finish(_ chord: String?, _ error: String?) {
        generation += 1; isStarting = false; isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        timer?.invalidate(); timer = nil
        resume?(); resume = nil; didFinish?(chord, error)
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        timer?.invalidate(); resume?()
    }
    static func chord(_ event: NSEvent) -> String? {
        let keys: [UInt16: String] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"equal",25:"9",26:"7",27:"minus",28:"8",29:"0",30:"rightbracket",31:"o",32:"u",33:"leftbracket",34:"i",35:"p",36:"return",37:"l",38:"j",39:"quote",40:"k",41:"semicolon",42:"backslash",43:"comma",44:"slash",45:"n",46:"m",47:"period",48:"tab",49:"space",50:"grave",51:"delete",117:"forwarddelete",115:"home",119:"end",116:"pageup",121:"pagedown",123:"leftarrow",124:"rightarrow",125:"downarrow",126:"uparrow",122:"f1",120:"f2",99:"f3",118:"f4",96:"f5",97:"f6",98:"f7",100:"f8",101:"f9",109:"f10",103:"f11",111:"f12",105:"f13",107:"f14",113:"f15",106:"f16",64:"f17",79:"f18",80:"f19",90:"f20"]
        guard let key = keys[event.keyCode] else { return nil }
        return chord(key: key, flags: event.modifierFlags)
    }
    static func chord(key: String, flags: NSEvent.ModifierFlags) -> String? {
        // Require a non-Shift modifier so typing and ordinary arrow navigation
        // cannot accidentally become global window-manager commands.
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        var modifiers: [String] = []
        for (flag, name): (NSEvent.ModifierFlags, String) in [(.control,"ctrl"),(.option,"alt"),(.command,"cmd"),(.shift,"shift")] { if flags.contains(flag) { modifiers.append(name) } }
        return modifiers.joined(separator: " + ") + " - " + key
    }
}
