import AppKit
import BlaiseCore

/// Blaise's single menu-bar identity: a waveform held inside a quiet orb.
/// Operational states add a small treatment without replacing the mark with an
/// unrelated icon. The drawing is vector-backed by `NSImage`, so it remains
/// crisp at every menu-bar scale and adapts to light/dark appearances.
@MainActor
enum BlaiseStatusIcon {
    enum VisualState: Equatable {
        case idle
        case meetingDetected
        case recording
        case paused
        case processing
        case grace
        case warning
        case alarm
        case handoffWarning
    }

    static func visualState(
        for state: IndicatorState, handoffWarning: Bool,
        meetingDetected: Bool
    ) -> VisualState {
        if meetingDetected, StatusBarController.canPromoteMeetingDetection(in: state) {
            return .meetingDetected
        }
        switch state {
        case .recording:
            return .recording
        case .warning:
            return .warning
        case .alarm:
            return .alarm
        case .paused:
            return handoffWarning ? .handoffWarning : .paused
        case .grace:
            return handoffWarning ? .handoffWarning : .grace
        case .processing:
            return handoffWarning ? .handoffWarning : .processing
        case .idle:
            return handoffWarning ? .handoffWarning : .idle
        }
    }

    static func image(for state: VisualState) -> NSImage {
        let color = tint(for: state)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = color ?? .black
            ink.setStroke()
            ink.setFill()

            let ring = NSBezierPath(ovalIn: NSRect(x: 2.1, y: 2.1, width: 13.8, height: 13.8))
            ring.lineWidth = 1.35
            if state == .processing {
                let pattern: [CGFloat] = [2.2, 1.8]
                ring.setLineDash(pattern, count: pattern.count, phase: 0)
            }
            ring.stroke()

            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 4.2, y: 8.8))
            wave.curve(
                to: NSPoint(x: 6.5, y: 8.8),
                controlPoint1: NSPoint(x: 4.9, y: 8.8),
                controlPoint2: NSPoint(x: 5.5, y: 6.4))
            wave.curve(
                to: NSPoint(x: 8.1, y: 8.8),
                controlPoint1: NSPoint(x: 7.0, y: 11.5),
                controlPoint2: NSPoint(x: 7.5, y: 12.7))
            wave.curve(
                to: NSPoint(x: 9.9, y: 8.8),
                controlPoint1: NSPoint(x: 8.7, y: 4.9),
                controlPoint2: NSPoint(x: 9.2, y: 5.2))
            wave.curve(
                to: NSPoint(x: 11.7, y: 8.8),
                controlPoint1: NSPoint(x: 10.6, y: 12.0),
                controlPoint2: NSPoint(x: 11.0, y: 10.4))
            wave.curve(
                to: NSPoint(x: 13.8, y: 8.8),
                controlPoint1: NSPoint(x: 12.4, y: 7.2),
                controlPoint2: NSPoint(x: 13.0, y: 8.8))
            wave.lineWidth = 1.25
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.stroke()

            drawStateTreatment(state, ink: ink)
            return true
        }
        image.accessibilityDescription = accessibilityDescription(for: state)
        image.isTemplate = color == nil
        return image
    }

    private static func drawStateTreatment(_ state: VisualState, ink: NSColor) {
        switch state {
        case .idle:
            break
        case .meetingDetected:
            // An attention spark at the top-right: new, actionable activity.
            let spark = NSBezierPath()
            spark.move(to: NSPoint(x: 14.3, y: 17.1))
            spark.line(to: NSPoint(x: 14.9, y: 15.4))
            spark.line(to: NSPoint(x: 16.7, y: 14.8))
            spark.line(to: NSPoint(x: 14.9, y: 14.2))
            spark.line(to: NSPoint(x: 14.3, y: 12.5))
            spark.line(to: NSPoint(x: 13.7, y: 14.2))
            spark.line(to: NSPoint(x: 12.0, y: 14.8))
            spark.line(to: NSPoint(x: 13.7, y: 15.4))
            spark.close()
            spark.fill()
        case .recording:
            NSBezierPath(ovalIn: NSRect(x: 12.9, y: 0.8, width: 4.2, height: 4.2)).fill()
        case .paused, .grace:
            let left = NSBezierPath(roundedRect: NSRect(x: 13.0, y: 0.8, width: 1.25, height: 4.5), xRadius: 0.6, yRadius: 0.6)
            let right = NSBezierPath(roundedRect: NSRect(x: 15.5, y: 0.8, width: 1.25, height: 4.5), xRadius: 0.6, yRadius: 0.6)
            left.fill(); right.fill()
        case .processing:
            let dot = NSBezierPath(ovalIn: NSRect(x: 13.5, y: 13.5, width: 3.2, height: 3.2))
            dot.fill()
        case .warning, .alarm, .handoffWarning:
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 14.9, y: 16.9))
            mark.line(to: NSPoint(x: 14.9, y: 13.1))
            mark.lineWidth = state == .alarm ? 1.8 : 1.4
            mark.lineCapStyle = .round
            mark.stroke()
            NSBezierPath(ovalIn: NSRect(x: 14.1, y: 10.9, width: 1.6, height: 1.6)).fill()
        }
    }

    private static func tint(for state: VisualState) -> NSColor? {
        switch state {
        case .idle, .processing, .grace:
            return nil
        case .meetingDetected, .paused:
            return .controlAccentColor
        case .recording:
            return .systemRed
        case .warning, .alarm, .handoffWarning:
            return .systemOrange
        }
    }

    private static func accessibilityDescription(for state: VisualState) -> String {
        switch state {
        case .idle: return "Blaise idle"
        case .meetingDetected: return "Blaise meeting detected"
        case .recording: return "Blaise recording"
        case .paused: return "Blaise recording paused"
        case .processing: return "Blaise processing"
        case .grace: return "Blaise waiting for rejoin"
        case .warning: return "Blaise recording warning"
        case .alarm: return "Blaise recording alarm"
        case .handoffWarning: return "Blaise Evidence Store warning"
        }
    }
}
