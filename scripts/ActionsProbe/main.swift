import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import SystemConfiguration

struct ProbeFailure: Error {
    let state: String
    let reason: String
    let code: Int32
    init(_ reason: String, state: String = "BLOCKED", code: Int32 = 3) {
        self.state = state
        self.reason = reason
        self.code = code
    }
}

struct ProcessFacts {
    let pid: pid_t
    let uid: uid_t
    let realUID: uid_t
    let ppid: pid_t
    let start: UInt64
    let executable: String
    var json: [String: Any] {
        ["pid": pid, "uid": uid, "ppid": ppid, "start_us": start, "executable": executable]
    }
    func matches(_ other: ProcessFacts) -> Bool {
        pid == other.pid && uid == other.uid && realUID == other.realUID
            && start == other.start && executable == other.executable
    }
}

struct ObservationOptions {
    let pid: pid_t
    let uid: uid_t
    let start: UInt64
    let samples: Int
    let interval: Int
    let includeContent: Bool
}

enum Command {
    case help
    case facts(pid_t)
    case observe(ObservationOptions)
}

func parse(_ arguments: [String]) throws -> Command {
    if arguments == ["--help"] || arguments == ["-h"] { return .help }
    if arguments.count == 2, arguments[0] == "--process-facts",
       let pid = pid_t(arguments[1]), pid > 0 { return .facts(pid) }
    guard arguments.first == "--observe" else { throw ProbeFailure("invalid_arguments", code: 2) }
    let contentCount = arguments.filter { $0 == "--include-content" }.count
    let pairs = Array(arguments.dropFirst().filter { $0 != "--include-content" })
    guard contentCount <= 1, pairs.count == 10 else { throw ProbeFailure("invalid_arguments", code: 2) }
    var flags: [String: String] = [:]
    for index in stride(from: 0, to: pairs.count, by: 2) {
        guard flags.updateValue(pairs[index + 1], forKey: pairs[index]) == nil else {
            throw ProbeFailure("duplicate_argument", code: 2)
        }
    }
    guard Set(flags.keys) == Set(["--pid", "--uid", "--start-us", "--samples", "--interval-ms"]),
          let pid = flags["--pid"].flatMap(pid_t.init), pid > 0,
          let uid = flags["--uid"].flatMap(uid_t.init),
          let start = flags["--start-us"].flatMap(UInt64.init), start > 0,
          let samples = flags["--samples"].flatMap(Int.init), (1...600).contains(samples),
          let interval = flags["--interval-ms"].flatMap(Int.init), (50...10_000).contains(interval),
          samples * interval <= 120_000 else { throw ProbeFailure("invalid_arguments", code: 2) }
    return .observe(ObservationOptions(pid: pid, uid: uid, start: start, samples: samples,
                                       interval: interval, includeContent: contentCount == 1))
}

func processFacts(_ pid: pid_t) throws -> ProcessFacts {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
        throw ProbeFailure("kernel_process_info_unavailable")
    }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
          let end = path.firstIndex(of: 0) else { throw ProbeFailure("kernel_process_path_unavailable") }
    var after = proc_bsdinfo()
    guard let executable = String(bytes: path[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8),
          !executable.isEmpty, info.pbi_pid == UInt32(pid), info.pbi_ppid <= Int32.max,
          info.pbi_start_tvusec < 1_000_000,
          info.pbi_start_tvsec <= (UInt64.max - info.pbi_start_tvusec) / 1_000_000,
          proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
          after.pbi_pid == info.pbi_pid, after.pbi_uid == info.pbi_uid, after.pbi_ruid == info.pbi_ruid,
          after.pbi_start_tvsec == info.pbi_start_tvsec, after.pbi_start_tvusec == info.pbi_start_tvusec else {
        throw ProbeFailure("kernel_process_identity_invalid_or_changed")
    }
    return ProcessFacts(pid: pid, uid: info.pbi_uid, realUID: info.pbi_ruid,
                        ppid: pid_t(info.pbi_ppid), start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                        executable: executable)
}

func validateAccount(_ uid: uid_t) throws {
    guard getuid() == geteuid(), getuid() == uid, uid != 0, uid != 501 else {
        throw ProbeFailure("unsafe_observer_account", code: 2)
    }
    var consoleUID: uid_t = 0
    var consoleGID: gid_t = 0
    guard let user = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID),
          user as String != "loginwindow", consoleUID == uid else {
        throw ProbeFailure("console_account_mismatch")
    }
}

func validateTarget(_ expected: ProcessFacts) throws {
    try validateAccount(expected.uid)
    guard try expected.matches(processFacts(expected.pid)), expected.realUID == expected.uid,
          let application = NSRunningApplication(processIdentifier: expected.pid), !application.isTerminated,
          application.bundleIdentifier == "com.apple.Notes",
          application.executableURL?.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: expected.executable).resolvingSymlinksInPath().path else {
        throw ProbeFailure("notes_process_identity_mismatch")
    }
}

func checkAX(_ result: AXError, _ field: String) throws {
    guard result == .success else {
        let unsupported = result == .attributeUnsupported || result == .notImplemented
        throw ProbeFailure("ax_\(field)_error_\(result.rawValue)", state: unsupported ? "UNSUPPORTED" : "BLOCKED")
    }
}

func attribute(_ element: AXUIElement, _ name: String, optional: Bool = false) throws -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    if optional && (result == .attributeUnsupported || result == .noValue) { return nil }
    try checkAX(result, "attribute")
    guard value != nil else { throw ProbeFailure("ax_attribute_missing", state: "UNSUPPORTED") }
    return value
}

func typedCF<T>(_ value: CFTypeRef, typeID: CFTypeID, as type: T.Type) -> T? {
    guard CFGetTypeID(value) == typeID else { return nil }
    return value as? T
}
func elementAttribute(_ element: AXUIElement, _ name: String) throws -> AXUIElement {
    guard let value = try attribute(element, name),
          let result = typedCF(value, typeID: AXUIElementGetTypeID(), as: AXUIElement.self) else {
        throw ProbeFailure("ax_element_type_unsupported", state: "UNSUPPORTED")
    }
    return result
}

func textAttribute(_ element: AXUIElement, _ name: String) throws -> String {
    guard let value = try attribute(element, name) else {
        throw ProbeFailure("ax_text_missing", state: "UNSUPPORTED")
    }
    if let text = value as? String { return text }
    if let text = value as? NSAttributedString { return text.string }
    throw ProbeFailure("ax_text_type_unsupported", state: "UNSUPPORTED")
}

func frame(_ window: AXUIElement) throws -> [String: Double] {
    guard let position = try attribute(window, kAXPositionAttribute),
          let size = try attribute(window, kAXSizeAttribute),
          let pointValue = typedCF(position, typeID: AXValueGetTypeID(), as: AXValue.self),
          let sizeValue = typedCF(size, typeID: AXValueGetTypeID(), as: AXValue.self) else {
        throw ProbeFailure("ax_frame_type_unsupported", state: "UNSUPPORTED")
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions),
          [point.x, point.y, dimensions.width, dimensions.height].allSatisfy({ $0.isFinite }),
          dimensions.width > 0, dimensions.height > 0 else {
        throw ProbeFailure("ax_frame_unreadable", state: "UNSUPPORTED")
    }
    return ["x": point.x, "y": point.y, "width": dimensions.width, "height": dimensions.height]
}

final class Observer {
    let epoch = UUID().uuidString
    let expected: ProcessFacts
    var generation = 0
    var window: AXUIElement?
    var focus: AXUIElement?
    var frontmost: Bool?
    init(_ expected: ProcessFacts) { self.expected = expected }
    var metadata: [String: Any] {
        ["pid": expected.pid, "uid": expected.uid, "start_us": expected.start,
         "bundle_id": NSNull(), "observer_epoch": epoch, "generation": generation,
         "frontmost": frontmost.map { $0 as Any } ?? NSNull()]
    }
    func invalidate() {
        generation += 1
        window = nil
        focus = nil
    }
    func focusedPair(_ app: AXUIElement) throws -> (AXUIElement, AXUIElement) {
        let window = try elementAttribute(app, kAXFocusedWindowAttribute)
        let focus = try elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        for element in [window, focus] {
            var pid: pid_t = 0
            try checkAX(AXUIElementGetPid(element, &pid), "owner")
            guard pid == expected.pid else { throw ProbeFailure("focused_target_owner_mismatch") }
        }
        guard CFEqual(try elementAttribute(focus, kAXWindowAttribute), window),
              CFEqual(try elementAttribute(app, kAXFocusedUIElementAttribute), focus) else {
            throw ProbeFailure("focused_window_mismatch")
        }
        return (window, focus)
    }
    func snapshot(includeContent: Bool) throws -> [String: Any] {
        frontmost = nil
        try validateTarget(expected)
        guard AXIsProcessTrusted() else { throw ProbeFailure("accessibility_permission_missing") }
        frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid
        guard frontmost == true else { throw ProbeFailure("notes_not_frontmost") }
        let app = AXUIElementCreateApplication(expected.pid)
        try checkAX(AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25), "timeout_configuration")
        let (newWindow, newFocus) = try focusedPair(app)
        if window.map({ CFEqual($0, newWindow) }) != true || focus.map({ CFEqual($0, newFocus) }) != true {
            generation += 1
            window = newWindow
            focus = newFocus
        }
        let role = try textAttribute(newFocus, kAXRoleAttribute)
        var settable = DarwinBoolean(false)
        try checkAX(AXUIElementIsAttributeSettable(newFocus, kAXValueAttribute as CFString, &settable), "editable")
        guard [kAXTextAreaRole, kAXTextFieldRole].contains(role), settable.boolValue else {
            throw ProbeFailure("focused_editor_unsupported", state: "UNSUPPORTED")
        }
        let value = try textAttribute(newFocus, kAXValueAttribute)
        guard value.utf8.count <= 65_536 else { throw ProbeFailure("editor_value_limit", state: "UNSUPPORTED") }
        let windowRole = try textAttribute(newWindow, kAXRoleAttribute)
        guard windowRole == kAXWindowRole else { throw ProbeFailure("window_role_unsupported", state: "UNSUPPORTED") }
        var windowInfo: [String: Any] = ["role": windowRole, "frame": try frame(newWindow)]
        let subrole = try attribute(newFocus, kAXSubroleAttribute, optional: true)
        let subroleText = subrole as? String
        guard subrole == nil || subroleText != nil, (subroleText?.utf8.count ?? 0) <= 256 else {
            throw ProbeFailure("ax_subrole_type_or_size_unsupported", state: "UNSUPPORTED")
        }
        var row = metadata
        row["state"] = "OBSERVED"
        row["bundle_id"] = "com.apple.Notes"
        row["focused"] = ["role": role, "subrole": subroleText.map { $0 as Any } ?? NSNull()]
        row["editable"] = true
        row["value_readable"] = true
        row["value_length"] = value.utf16.count
        if includeContent {
            let title = try textAttribute(newWindow, kAXTitleAttribute)
            guard title.utf8.count <= 4_096 else { throw ProbeFailure("window_title_limit", state: "UNSUPPORTED") }
            windowInfo["title"] = title
            row["value"] = value
            row["value_sha"] = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        row["window"] = windowInfo
        let (lastWindow, lastFocus) = try focusedPair(app)
        frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid
        guard CFEqual(newWindow, lastWindow), CFEqual(newFocus, lastFocus), frontmost == true else {
            throw ProbeFailure("focus_changed_during_sample")
        }
        try validateTarget(expected)
        return row
    }
}

func emit(_ row: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

func observe(_ options: ObservationOptions) throws {
    dispatchPrecondition(condition: .onQueue(.main))
    try validateAccount(options.uid)
    let expected = try processFacts(options.pid)
    guard expected.uid == options.uid, expected.start == options.start else {
        throw ProbeFailure("requested_process_identity_mismatch")
    }
    let observer = Observer(expected)
    for sample in 0..<options.samples {
        do {
            try autoreleasepool { try emit(observer.snapshot(includeContent: options.includeContent)) }
        } catch let failure as ProbeFailure {
            observer.invalidate()
            var row = observer.metadata
            row.merge(["state": failure.state, "reason": failure.reason, "window": NSNull(),
                       "focused": NSNull(), "editable": false, "value_readable": false,
                       "value_length": NSNull()]) { _, value in value }
            try emit(row)
            exit(failure.code)
        }
        if sample + 1 < options.samples { RunLoop.current.run(until: Date(timeIntervalSinceNow: Double(options.interval) / 1_000)) }
    }
}

do {
    switch try parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        let usage = """
        ActionsProbe --process-facts PID
        ActionsProbe --observe --pid PID --uid UID --start-us N --samples N --interval-ms N [--include-content]
        Read-only Notes observations. UID 0/501 and non-console accounts are denied. No permission prompts.
        Samples 1...600; interval 50...10000 ms; samples * interval <= 120000 ms. Values <= 65536 UTF-8 bytes.
        NDJSON state OBSERVED is not screenshot-correlated native proof. Value length uses UTF-16 code units.
        Titles, values and value_sha SHA-256 appear only with --include-content. Output is stdout only.
        Exit 0 completed requested reads; 2 invalid/unsafe request; 3 BLOCKED/UNSUPPORTED; 4 unexpected failure.
        """
        try FileHandle.standardOutput.write(contentsOf: Data((usage + "\n").utf8))
    case .facts(let pid): try emit(processFacts(pid).json)
    case .observe(let options): try observe(options)
    }
} catch let failure as ProbeFailure {
    try? emit(["state": failure.state, "reason": failure.reason])
    exit(failure.code)
} catch {
    try? emit(["state": "BLOCKED", "reason": "observer_io_or_internal_failure"])
    exit(4)
}
