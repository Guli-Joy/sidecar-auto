// DisplayState.swift
//
// Small, dependency-free display probe for the headless connection path.  It uses
// CoreGraphics for the online display list and AppKit only for the human name.
// Build on the Mac with:
//   swiftc -O DisplayState.swift -o display-state

import AppKit
import CoreGraphics
import Foundation

private func screenName(_ id: CGDirectDisplayID) -> String {
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDirectDisplayID(number.uint32Value) == id else { continue }
        return screen.localizedName
    }
    return ""
}

private func displayKind(_ id: CGDirectDisplayID, _ name: String) -> String {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let vendor = CGDisplayVendorNumber(id)
    let model = CGDisplayModelNumber(id)

    // BetterDisplay virtual screens report vendor 2198. Names are a fallback
    // for other virtual outputs and the generic no-monitor placeholder. This
    // check must precede the Sidecar name hints: the configured fallback is
    // commonly named "SidecarSwitchVirtual", which contains "sidecar" but is
    // still a virtual display and must not count as an online Sidecar panel.
    // A monitor adapter can leave a CoreGraphics placeholder online after the
    // cable is removed.  On this Mac that output has no AppKit name and uses
    // the IOKit "unknown/virt" vendor-model pair (ASCII `unkn`/`virt`).
    // BetterDisplay reports the same output as "Generic Display".  Treat the
    // pair as virtual so a stale placeholder cannot block headless Sidecar.
    let genericPlaceholder = vendor == 0x756e6b6e && model == 0x76697274
    if vendor == 2198 || genericPlaceholder || ["virtual", "dummy", "headless", "remote display"].contains(where: { n.contains($0) }) ||
       n == "generic" || n == "generic display" {
        return "virtual"
    }

    // Match Sidecar using the hardware identity that SidecarSwitch uses, then
    // fall back to stable name hints used by macOS across releases.
    if vendor == 0x6161706C || model == 0x69506164 ||
       ["sidecar", "ipad", "airplay", "continuity", "screen sharing"].contains(where: { n.contains($0) }) {
        return "sidecar"
    }
    return "physical"
}

var count: UInt32 = 0
var displays = [CGDirectDisplayID](repeating: 0, count: 32)
let result = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)
guard result == .success else {
    fputs("error=coregraphics_\(result.rawValue)\n", stderr)
    exit(2)
}

var physicalCount = 0
var sidecarCount = 0
var virtualCount = 0
var rows: [String] = []

for id in displays.prefix(Int(count)) where CGDisplayIsOnline(id) != 0 {
    let builtin = CGDisplayIsBuiltin(id) != 0
    let inMirrorSet = CGDisplayIsInMirrorSet(id) != 0
    let name = screenName(id)
    let kind = builtin ? "builtin" : displayKind(id, name)
    if kind == "sidecar" { sidecarCount += 1 }
    if kind == "virtual" { virtualCount += 1 }
    if kind == "physical" { physicalCount += 1 }
    let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "\n", with: " ")
                     .replacingOccurrences(of: " ", with: "_")
    rows.append("display id=\(id) kind=\(kind) builtin=\(builtin ? 1 : 0) main=\(CGDisplayIsMain(id) != 0 ? 1 : 0) mirror=\(inMirrorSet ? 1 : 0) name=\(escaped)")
}

print("physical=\(physicalCount)")
print("sidecar=\(sidecarCount)")
print("virtual=\(virtualCount)")
for row in rows.sorted() { print(row) }
