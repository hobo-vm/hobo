import CoreGraphics
import Foundation
import HoboUICore

/// Real input events, posted where the HID system would post a person's: what the app sees is
/// a mouse or keyboard, with hit-testing, focus and the responder chain as they'd be.
/// (System Events' `click at` returns without clicking in a guest; these work.)
enum Input {
    static func flags(_ modifiers: [Modifier]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
        return flags
    }

    static func move(to point: CGPoint) {
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        pause(0.03)
    }

    static func click(at point: CGPoint, right: Bool = false, count: Int = 1, modifiers: [Modifier] = []) {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        move(to: point)
        for click in 1...count {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.flags = flags(modifiers)
                post(event)
                pause(0.02)
            }
        }
    }

    /// Down, a move in steps over about 300 ms, a pause over the target (drop targets often want
    /// one before they accept), and up.
    static func drag(from start: CGPoint, to end: CGPoint, modifiers: [Modifier] = []) {
        let flags = flags(modifiers)
        move(to: start)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)
        down?.flags = flags
        post(down)
        pause(0.1)
        let steps = 20
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
            drag?.flags = flags
            post(drag)
            pause(0.015)
        }
        pause(0.3)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)
        up?.flags = flags
        post(up)
        pause(0.1)
    }

    static func scroll(at point: CGPoint, _ direction: HoboUI.ScrollDirection, lines: Int) {
        move(to: point)
        let (vertical, horizontal): (Int32, Int32) = switch direction {
        case .up: (1, 0)
        case .down: (-1, 0)
        case .left: (0, 1)
        case .right: (0, -1)
        }
        for _ in 0..<lines {
            post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0))
            pause(0.02)
        }
        pause(0.1)
    }

    static func key(_ spec: KeySpec) {
        let flags = flags(spec.modifiers)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: spec.keyCode, keyDown: down)
            event?.flags = flags
            post(event)
            pause(0.02)
        }
    }

    /// Each character as a key event carrying it as Unicode, whatever the keyboard layout.
    static func type(_ text: String) {
        for character in text {
            if character == "\n" || character == "\r" {
                key(KeySpec(modifiers: [], keyCode: 0x24))
                continue
            }
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event)
            }
            pause(0.008)
        }
        pause(0.05)
    }

    private static func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

    static func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}
