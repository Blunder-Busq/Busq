import XCTest
@testable import Busq

class BusqTests: XCTestCase {
    override class func setUp() {
        //MobileDevice.debug = true
    }

    override class func tearDown() {
        //MobileDevice.debug = false
    }

//    func testDeviceConnectionPerformance() throws {
//        measure {
//            do {
//                try listApps()
//            } catch {
//                XCTFail("\(error)")
//            }
//        }
//    }

    func testDeviceConnection() throws {
        try listApps()
    }

    func listApps(type appType: ApplicationType = .any) throws {
        print("Getting device list…")

        // this throws an error on Linux, but just returns an empty array on macOS
        let deviceInfos = (try? DeviceManager.getDeviceListExtended()) ?? []

        print("Devices:", deviceInfos.count)
        for deviceInfo in deviceInfos {
            print("device:", deviceInfo.udid, "connectionType:", deviceInfo.connectionType)
            let device = try Device(udid: deviceInfo.udid, options: deviceInfo.connectionType == .network ? .network : .usbmux)
            print(" - handle:", try device.getHandle())

            let lfc = try device.createLockdownClient()
            print(" - lockdown client:", try lfc.getName()) // “Bob's iPhone”
            print(" - device UDID:", try lfc.getDeviceUDID())
            print(" - query:", try lfc.getQueryType()) // “com.apple.mobile.lockdown”

            print(" - battery:", try lfc.getValue(domain: "com.apple.mobile.battery", key: "BatteryCurrentCapacity").uint ?? 0) // e.g.: 100

            let proxy = try lfc.createInstallationProxy()
            
            print("created proxy:", proxy)

            let opts = Plist(dictionary: [
                "ApplicationType": Plist(string: appType.rawValue)
            ])

            let appsPlists = try proxy.browse(options: opts)
            if let appPlists = appsPlists.array {
                print("app list:", Array(appPlists).count)
                for appInfo in appPlists.map(InstalledAppInfo.init) {
                    print(" - app:", appInfo.CFBundleIdentifier ?? "", "name:", appInfo.CFBundleDisplayName ?? "", "version:", appInfo.CFBundleShortVersionString ?? "") // , "keys:", appInfo.dict.keys.sorted())
                }
            }
        }
    }
}
