// G5 capture helper: prints the CGWindowID of the SETTINGS window (620×600) of
// the Blaise instance with the given PID — distinct from the wide main window.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: g5_settings_windowid.swift <pid>\n".utf8))
    exit(2)
}
let info =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
// The Settings window is .frame(width: 620, height: 600). Match the window
// whose width is closest to 620 (the main window is much wider).
var best: (number: Int, delta: Double)?
for window in info {
    guard
        let owner = window[kCGWindowOwnerPID as String] as? Int, owner == pid,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double, width > 400,
        let number = window[kCGWindowNumber as String] as? Int
    else { continue }
    let delta = abs(width - 620)
    if best == nil || delta < best!.delta { best = (number, delta) }
}
if let best {
    print(best.number)
} else {
    FileHandle.standardError.write(Data("no Blaise settings window found\n".utf8))
    exit(1)
}
