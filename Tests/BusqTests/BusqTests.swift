import XCTest
@testable import Busq

class BusqTests: XCTestCase {
    override class func setUp() {
        //MobileDevice.debug = true
    }

    override class func tearDown() {
        //MobileDevice.debug = false
    }

    func testDeviceConnectionPerformance() throws {
        throw XCTSkip() // skipping for performace

        measure {
            do {
                try deviceConnectionTest()
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testDeviceConnection() throws {
        try deviceConnectionTest()
    }

    func deviceConnectionTest() throws {
        print("Getting device list…")

        // this throws an error on Linux, but just returns an empty array on macOS
        let deviceInfos = (try? DeviceManager.getDeviceListExtended()) ?? []

        print("Devices:", deviceInfos.count)
        for deviceInfo in deviceInfos {
            print("device:", deviceInfo.udid, "connectionType:", deviceInfo.connectionType)
            let device = try Device(udid: deviceInfo.udid, options: deviceInfo.connectionType == .network ? .network : .usbmux)
            print(" - handle:", try device.getHandle())

            let lfc = try device.createLockdownClient()
            try testLockdownClient(lfc)
            try testAppList(lfc)

            try testInstallationProxy(lfc)
            try testFileConduit(lfc) // AFC_E_MUX_ERROR
            try testFileRelayClient(lfc)
            try testHouseArrestClient(lfc)
            try testSyslogRelayClient(lfc)
            try testSpringboardServiceClient(lfc)
            // try testDebugServer(lfc) // seems to require manual start of the service
        }
    }

    func testLockdownClient(_ lfc: LockdownClient) throws {
        print(" - lockdown client:", try lfc.getName()) // “Bob's iPhone”
        print(" - device UDID:", try lfc.getDeviceUDID())
        print(" - query:", try lfc.getQueryType()) // “com.apple.mobile.lockdown”

        print(" - battery:", try lfc.getValue(domain: "com.apple.mobile.battery", key: "BatteryCurrentCapacity").uint ?? 0) // e.g.: 100
    }

    func testInstallationProxy(_ lfc: LockdownClient) throws {
        let client = try lfc.createInstallationProxy()
        let _ = client
    }

    func testDebugServer(_ lfc: LockdownClient) throws {
        let client = try lfc.createDebugServer()
        let _ = client
    }

    func testFileConduit(_ lfc: LockdownClient) throws {
        let client = try lfc.createFileConduit()
        let _ = client
    }

    func testHouseArrestClient(_ lfc: LockdownClient) throws {
        let client = try lfc.createHouseArrestClient()
        let _ = client
   }

    func testFileRelayClient(_ lfc: LockdownClient) throws {
        let client = try lfc.createFileRelayClient()
        let _ = client
    }

    func testSyslogRelayClient(_ lfc: LockdownClient) throws {
        let client = try lfc.createSyslogRelayClient()
        let _ = client
    }

    func testSpringboardServiceClient(_ lfc: LockdownClient) throws {
        let client = try lfc.createSpringboardServiceClient()
        let _ = client
    }

    func testAppList(_ lfc: LockdownClient, type appType: ApplicationType = .any) throws {
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
