// Drive the booted simulator by synthesizing taps and drags.
//
//   swift Scripts/sim-input.swift tap  <x> <y>
//   swift Scripts/sim-input.swift drag <x1> <y1> <x2> <y2>
//   swift Scripts/sim-input.swift type <text>
//   printf '%s' "$SECRET" | swift Scripts/sim-input.swift type      # reads stdin
//
// `type` sends keystrokes to the focused field, which needs the Simulator's "Connect Hardware
// Keyboard" (I/O menu) left on — it is by default. Prefer the stdin form for anything secret: an
// argument is visible in the process list, which is the same reason smoke.sh reads its key from .env.
//
// Coordinates are in the pixel space of `xcrun simctl io booted screenshot`, so you can read a
// target straight off a screenshot instead of converting anything by hand. The device screen's
// position and scale are looked up at run time through the accessibility API (the Simulator exposes
// the screen as an `iOSContentGroup`), which means the window can be moved, resized, or on a second
// display and this still lands in the right place.
//
// `SIM_DEVICE` picks which device to drive, by name, when more than one is booted:
//
//   SIM_DEVICE="bangui iPhone 17 Pro" swift Scripts/sim-input.swift tap 100 200
//
// Unset means `booted` and the only window, which is right for one device. It stops being right the
// moment a second workspace boots its own: `booted` then resolves to *a* device rather than the one
// you are watching, and the first Simulator window is whichever the window server hands over. So
// with several windows open and no name given, this stops rather than guessing — a tap that lands on
// another workspace's simulator looks exactly like the app ignoring input.
//
// The name is matched against the window title, which the Simulator formats as "<device> – <runtime>",
// and only at the start: "iPhone 17 Pro" must not match the window titled "bangui iPhone 17 Pro".
//
// Requirements, both of which fail confusingly rather than loudly:
//   1. The calling process needs Accessibility permission (System Settings → Privacy & Security →
//      Accessibility). Without it CGEventPost silently does nothing.
//   2. **The Mac must be unlocked with an awake display.** macOS drops synthesized events while the
//      console is locked, so every tap appears to do nothing at all. Check with:
//      `ioreg -n Root -d1 -r | grep IOConsoleLocked`
//
// Used for the per-phase live pass described in PLAN.md's Verification section: build, `make run`,
// then drive the screens the phase added and screenshot each step.
import AppKit
import ApplicationServices
import CoreGraphics

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("!!! \(message)\n".utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// Depth-first search for the device screen inside the Simulator's window.
func findDeviceScreen(_ element: AXUIElement, depth: Int = 0) -> CGRect? {
    guard depth < 6 else { return nil }
    if attribute(element, kAXSubroleAttribute) as? String == "iOSContentGroup" {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let position = attribute(element, kAXPositionAttribute) {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        if let boxSize = attribute(element, kAXSizeAttribute) {
            AXValueGetValue(boxSize as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = findDeviceScreen(child, depth: depth + 1) { return found }
    }
    return nil
}

/// The device to drive: a name from `SIM_DEVICE`, or whatever `booted` resolves to.
let deviceTarget = ProcessInfo.processInfo.environment["SIM_DEVICE"].flatMap {
    $0.isEmpty ? nil : $0
}

/// Width of the current screenshot in pixels, to derive the point-per-pixel scale.
func screenshotWidth() -> CGFloat {
    let path = NSTemporaryDirectory() + "sim-input-probe.png"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "io", deviceTarget ?? "booted", "screenshot", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    guard let image = NSImage(contentsOfFile: path),
          let rep = image.representations.first
    else { fail("couldn't screenshot the booted simulator — is one running?") }
    return CGFloat(rep.pixelsWide)
}

guard !AXIsProcessTrusted() == false else {
    fail("no Accessibility permission — grant it to this terminal in System Settings → Privacy & Security → Accessibility")
}

guard let simulator = NSWorkspace.shared.runningApplications
    .first(where: { $0.localizedName == "Simulator" })
else { fail("Simulator isn't running — try `make run`") }

let axApp = AXUIElementCreateApplication(simulator.processIdentifier)
let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
func title(of window: AXUIElement) -> String { attribute(window, kAXTitleAttribute) as? String ?? "" }

// With `SIM_DEVICE` set, the window has to be the one titled for that device — taking the first
// window would land every tap on another workspace's simulator, which looks like the app ignoring
// input rather than like input going somewhere else. Matched on a whole name at the start rather
// than anywhere in the title, so "iPhone 17 Pro" doesn't also select "bangui iPhone 17 Pro".
let candidates: [AXUIElement]
if let deviceTarget {
    candidates = windows.filter { title(of: $0).hasPrefix(deviceTarget + " ") }
    if candidates.isEmpty {
        fail("""
            no Simulator window titled for '\(deviceTarget)' — is that device booted? \
            open: \(windows.map(title).joined(separator: ", "))
            """)
    }
} else if windows.count > 1 {
    // The same wrong-window tap, arrived at by saying nothing rather than by saying the wrong thing.
    fail("""
        \(windows.count) Simulator windows are open (\(windows.map(title).joined(separator: ", "))) \
        — set SIM_DEVICE to the device name so this doesn't drive the wrong one
        """)
} else {
    candidates = windows
}
guard let screen = candidates.lazy.compactMap({ findDeviceScreen($0) }).first
else { fail("couldn't find the simulator's device screen") }

let scale = screenshotWidth() / screen.width
func screenPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: screen.minX + x / scale, y: screen.minY + y / scale)
}

func post(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first
var numbers: [CGFloat] = []
for argument in arguments.dropFirst() {
    if let value = Double(argument) { numbers.append(CGFloat(value)) }
}

/// US-layout virtual key codes for the characters worth typing into a simulator.
///
/// A layout table, and not `keyboardSetUnicodeString`, because the Simulator's HID path honors the
/// **key code** and ignores an attached Unicode string: every character posted with `virtualKey: 0`
/// arrives as "a". That fails silently — a 32-character API key becomes 32 a's and the app reports a
/// rejected key — which is why an unmappable character below is a hard error instead.
let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, " ": 49, "`": 50,
]

/// Characters reached by holding shift, mapped to the unshifted key that produces them.
let shiftedKeyCodes: [Character: CGKeyCode] = [
    "_": 27, ":": 41, "?": 44, "+": 24, "{": 33, "}": 30, "|": 42, "<": 43, ">": 47,
    "\"": 39, "~": 50, "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26,
    "*": 28, "(": 25, ")": 29,
]

func keystroke(for character: Character) -> (code: CGKeyCode, shift: Bool) {
    if let code = keyCodes[character] { return (code, false) }
    if character.isUppercase, let code = keyCodes[Character(character.lowercased())] {
        return (code, true)
    }
    if let code = shiftedKeyCodes[character] { return (code, true) }
    fail("can't type '\(character)' — no key code for it, and guessing would type the wrong character")
}

/// Left shift, pressed as a real key rather than only set as an event flag.
let shiftKeyCode: CGKeyCode = 56

/// Keyboard events need a **real event source**. Built with `nil`, the Simulator drops the shift
/// modifier entirely — "_" arrives as "-" and every capital arrives lowercased, silently. Mouse
/// events are unaffected, which is why `post(_:at:)` below still passes nil.
let keyboardSource = CGEventSource(stateID: .hidSystemState)

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: keyboardSource, virtualKey: code, keyDown: down)
    else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    // Slow enough that a SwiftUI TextField's per-keystroke work can keep up; a tight loop drops
    // characters, which on an API key looks like the key being wrong.
    usleep(12_000)
}

/// Sends `text` as keystrokes, one character at a time.
///
/// Shift is held as an actual key-down/key-up pair around the character *and* set as a flag on it.
/// Both, because that's the combination that survives the trip into the device.
func typeText(_ text: String) {
    for character in text {
        let (code, shift) = keystroke(for: character)
        if shift { postKey(shiftKeyCode, down: true, flags: .maskShift) }
        postKey(code, down: true, flags: shift ? .maskShift : [])
        postKey(code, down: false, flags: shift ? .maskShift : [])
        if shift { postKey(shiftKeyCode, down: false) }
    }
}

simulator.activate()
usleep(250_000)

if command == "press" {
    // Named keys a form needs: clearing a field, submitting it, moving on.
    let namedKeys: [String: CGKeyCode] = ["delete": 51, "return": 36, "tab": 48, "escape": 53, "space": 49]
    guard arguments.count > 1, let code = namedKeys[arguments[1]] else {
        fail("usage: sim-input.swift press <\(namedKeys.keys.sorted().joined(separator: "|"))> [count]")
    }
    let count = arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1
    for _ in 0..<count {
        postKey(code, down: true)
        postKey(code, down: false)
    }
    print("pressed \(arguments[1]) \(count)x")
    exit(0)
}

if command == "type" {
    let text = arguments.count > 1
        ? arguments[1]
        : String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { fail("nothing to type — pass text as an argument or on stdin") }
    typeText(text)
    // The text itself is never echoed: this is the path an API key takes.
    print("typed \(text.count) characters")
    exit(0)
}

switch (command, numbers.count) {
case ("tap", 2):
    let point = screenPoint(numbers[0], numbers[1])
    post(.mouseMoved, at: point)
    usleep(50_000)
    post(.leftMouseDown, at: point)
    usleep(80_000)
    post(.leftMouseUp, at: point)
    print("tapped \(Int(numbers[0])),\(Int(numbers[1]))")

case ("drag", 4):
    let from = screenPoint(numbers[0], numbers[1])
    let to = screenPoint(numbers[2], numbers[3])
    post(.mouseMoved, at: from)
    usleep(50_000)
    post(.leftMouseDown, at: from)
    // Interpolated, because a single jump reads as a teleport and UIKit won't treat it as a swipe.
    for step in 1...10 {
        let t = CGFloat(step) / 10
        post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(20_000)
    }
    usleep(80_000)
    post(.leftMouseUp, at: to)
    print("dragged \(Int(numbers[0])),\(Int(numbers[1])) -> \(Int(numbers[2])),\(Int(numbers[3]))")

default:
    fail("usage: sim-input.swift tap <x> <y> | drag <x1> <y1> <x2> <y2> | type [text]")
}
