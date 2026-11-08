// lidprobe — prints the MacBook lid angle from the hidden HID sensor.
// Build: swiftc -O lidprobe.swift -o lidprobe   Run: ./lidprobe [--once]
import Foundation
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [
    kIOHIDVendorIDKey: 0x05AC,
    kIOHIDProductIDKey: 0x8104,
    kIOHIDPrimaryUsagePageKey: 0x0020,   // Sensor page
    kIOHIDPrimaryUsageKey: 0x008A,       // Orientation
]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = set.first else {
    print("NO SENSOR: lid-angle HID device (05AC:8104, page 0x20) not found.")
    exit(1)
}
guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("Found the device but could not open it."); exit(2)
}

func readAngle() -> Int? {
    var report = [UInt8](repeating: 0, count: 8)
    var length = CFIndex(report.count)
    let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
    guard r == kIOReturnSuccess, length >= 3 else { return nil }
    return Int(UInt16(report[1]) | UInt16(report[2]) << 8)   // byte 0 = report ID
}

// Pushed input reports (the sensor sends these on its own; count them per second).
var pushes = 0
let pushBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
IOHIDDeviceRegisterInputReportCallback(device, pushBuf, 16, { _, _, _, _, _, _, _ in pushes += 1 }, nil)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let once = CommandLine.arguments.contains("--once")
var last = -1, tick = 0
print("Lid-angle sensor found. Move the lid (Ctrl-C to quit).")
while true {
    if let a = readAngle(), a != last { print("angle: \(a)°"); last = a }
    if once { break }
    CFRunLoopRunInMode(.defaultMode, 0.05, false)        // also delivers pushed reports
    tick += 1
    if tick % 20 == 0 { print("  pushed reports last second: \(pushes)"); pushes = 0 }
    fflush(stdout)
}
