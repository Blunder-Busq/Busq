import XCTest
@testable import Busq

class BusqTests: XCTestCase {
    override class func setUp() {
        MobileDevice.debug = true
    }

    override class func tearDown() {
        MobileDevice.debug = false
    }
    
    func testDeviceConnection() throws {
        let deviceInfos = try MobileDevice.getDeviceListExtended()

        print("Devices:", deviceInfos.count)
        for deviceInfo in deviceInfos {
            print("device:", deviceInfo.udid, "connectionType:", deviceInfo.connectionType)
            let device = try Device(udid: deviceInfo.udid, options: deviceInfo.connectionType == .network ? .network : .usbmux)
            print(" - handle:", try device.getHandle())

            let lfc = try LockdownClient(device: device, withHandshake: true)
            print(" - lockdown client:", try lfc.getName()) // “Bob's iPhone”
            print(" - device UDID:", try lfc.getDeviceUDID())
            print(" - query:", try lfc.getQueryType()) // “com.apple.mobile.lockdown”

            // start the "com.apple.mobile.installation_proxy" service
            var service = try lfc.getService(identifier: AppleServiceIdentifier.installationProxy.rawValue, withEscroBag: true)
            defer { service.free() }

            let proxy = try InstallationProxy(device: device, service: service)
            print("created proxy:", proxy)

            let opts = Plist(dictionary: [
                "ApplicationType": Plist(string: "Any")
                //"ApplicationType": Plist(string: "System")
                //"ApplicationType": Plist(string: "User")
                //"ApplicationType": Plist(string: "Internal")
            ])

            let appsPlists = try proxy.browse(options: opts)
            if let appPlists = appsPlists.array {
                print("app list:", Array(appPlists).count)
                for appPlist in appPlists {
                    print(" - app:", appPlist)
                    if let dicti: PlistDictIterator = appPlist.dictionary?.makeIterator() {
                        while let keyValue = dicti.next() {
                            if keyValue.key == "CFBundleName" {
                                print("   - key:", keyValue.key, "value:", keyValue.value.string ?? keyValue.value.bool?.description ?? keyValue.value.real?.description ?? "unknown")
                            }
                        }
                    }
                }
            }

//            let appsPlists = try proxy.browse(options: opts, callback: { p1, p2 in
//                print("app:", p1, "usr data:", p2)
//            })

        }
    }
}
