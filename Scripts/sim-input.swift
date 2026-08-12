// Drive the booted simulator by synthesizing taps and drags.
//
//   swift Scripts/sim-input.swift tap  <x> <y>
//   swift Scripts/sim-input.swift drag <x1> <y1> <x2> <y2>
//
// Coordinates are in the pixel space of `xcrun simctl io booted screenshot`, so you can read a
// target straight off a screenshot instead of converting anything by hand. The device screen's
// position and scale are looked up at run time through the accessibility API (the Simulator exposes
// the screen as an `iOSContentGroup`), which means the window can be moved, resized, or on a second
// display and this still lands in the right place.
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

/// Width of the current screenshot in pixels, to derive the point-per-pixel scale.
func screenshotWidth() -> CGFloat {
    let path = NSTemporaryDirectory() + "sim-input-probe.png"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "io", "booted", "screenshot", path]
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
guard let window = (attribute(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first,
      let screen = findDeviceScreen(window)
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

simulator.activate()
usleep(250_000)

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
    fail("usage: sim-input.swift tap <x> <y> | drag <x1> <y1> <x2> <y2>")
}
