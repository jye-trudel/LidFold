import Foundation
import IOKit.hid

/// Reads the hidden lid-angle sensor (Apple 05AC:8104, Sensor page 0x20, Orientation usage 0x8A)
/// via a HID feature report: report ID 1, 16-bit little-endian degrees.
final class LidSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var report = [UInt8](repeating: 0, count: 8)
    private let pushBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)

    /// Input reports the sensor pushes on its own (≈1 Hz heartbeat while still; possibly faster
    /// while moving). Delivered on the main run loop — no polling, no extra thread.
    var onPush: ((Double) -> Void)?

    var isOpen: Bool { device != nil }

    @discardableResult
    func open() -> Bool {
        close()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x0020, kIOHIDPrimaryUsageKey: 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,
              let dev = devices.first,
              IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return false }
        manager = m
        device = dev
        IOHIDDeviceRegisterInputReportCallback(dev, pushBuffer, 16, { ctx, result, _, _, id, rep, len in
            guard result == kIOReturnSuccess, id == 1, len >= 3, let ctx else { return }
            let me = Unmanaged<LidSensor>.fromOpaque(ctx).takeUnretainedValue()
            let deg = Double(UInt16(rep[1]) | UInt16(rep[2]) << 8)
            if deg <= 360 { me.onPush?(deg) }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        return true
    }

    func close() {
        if let dev = device {
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
    }

    /// One synchronous feature-report read (~0.4 ms). Re-opens the device once on failure
    /// (it can go stale across sleep).
    func readAngle() -> Double? {
        if let a = readOnce() { return a }
        guard open() else { return nil }
        return readOnce()
    }

    private func readOnce() -> Double? {
        guard let dev = device else { return nil }
        var length = CFIndex(report.count)
        let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &report, &length)
        guard r == kIOReturnSuccess, length >= 3 else { return nil }
        let deg = Double(UInt16(report[1]) | UInt16(report[2]) << 8)
        return deg <= 360 ? deg : nil
    }
}
