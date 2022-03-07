import XCTest
@testable import Busq

class BusqTests: XCTestCase {
    func testDeviceConnection() throws {
        let devices = try MobileDevice.getDeviceListExtended()

        print("Devices:", devices.count)
        for device in devices {
            print("device:", device.udid, "connectionType:", device.connectionType)
            let dev = try Device(udid: device.udid, options: device.connectionType == .network ? .network : .usbmux)
            print(" - handle:", try dev.getHandle())
        }
    }
}
