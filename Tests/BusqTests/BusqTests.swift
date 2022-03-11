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
            if deviceInfo.connectionType == .network {
                continue // skip wireless connections while testing for efficiency
            }

            let device = try Device(udid: deviceInfo.udid, options: deviceInfo.connectionType == .network ? .network : .usbmux)
            print(" - handle:", try device.getHandle())

            let lfc = try device.createLockdownClient()
            try testLockdownClient(lfc)
            try testFileConduit(lfc)

            // try testAppList(lfc)
            // try testInstallationProxy(lfc)
            // try testSpringboardServiceClient(lfc)
            // try testHouseArrestClient(lfc)
            // try testSyslogRelayClient(lfc)


            // try testFileRelayClient(lfc) // muxError
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
        let client = try lfc.createInstallationProxy(escrow: true)
        let _ = client
    }

    func testDebugServer(_ lfc: LockdownClient) throws {
        let client = try lfc.createDebugServer(escrow: true)
        let _ = client
    }

    func testFileConduit(_ lfc: LockdownClient) throws {
        let client = try lfc.createFileConduit(escrow: false)

        let info = try client.getDeviceInfo()
        print(" - device info:", info) // AFC_E_MUX_ERROR
        // ["Model": "iPad5,3", "FSTotalBytes": "127993663488", "FSFreeBytes": "117186351104", "FSBlockSize": "4096"]
        XCTAssertNotNil(info["Model"])
        XCTAssertNotNil(info["FSTotalBytes"])
        XCTAssertNotNil(info["FSFreeBytes"])
        XCTAssertNotNil(info["FSBlockSize"])

        // [".", "..", "Downloads", "Books", "Photos", "Recordings", "DCIM", "iTunes_Control", "MediaAnalysis", "PhotoData", "Purchases"]
        print(" - dir:", try client.readDirectory(path: "/"))

        // e.g.: [".", "..", "downloads.28.sqlitedb", "downloads.28.sqlitedb-shm", "downloads.28.sqlitedb-wal"]
        print(" - downloads dir:", try client.readDirectory(path: "/Downloads"))

        // test reading and writing
        let dirname = UUID().uuidString
        print(" - mkdir:", try client.makeDirectory(path: "/\(dirname)/y/z"))
        print(" - rmdir:", try client.removePathAndContents(path: "/\(dirname)"))

    }

    func testHouseArrestClient(_ lfc: LockdownClient) throws {
        let client = try lfc.createHouseArrestClient(escrow: true)
        let _ = client
   }

    func testFileRelayClient(_ lfc: LockdownClient) throws {
        let client = try lfc.createFileRelayClient(escrow: true)
        let _ = client
    }

    func testSyslogRelayClient(_ lfc: LockdownClient) throws {
        let client = try lfc.createSyslogRelayClient(escrow: true)
        let _ = client
    }

    func testSpringboardServiceClient(_ lfc: LockdownClient) throws {
        let client = try lfc.createSpringboardServiceClient(escrow: true)
        let wallpaper = try client.getHomeScreenWallpaperPNGData()
        XCTAssertNotEqual(0, wallpaper.count)

        let appIcon = try client.getIconPNGData(bundleIdentifier: "com.apple.AppStore")
        XCTAssertNotEqual(0, appIcon.count) // 14071

        let noAppIcon = try client.getIconPNGData(bundleIdentifier: "")
        XCTAssertNotEqual(0, noAppIcon.count) // 9881 seems to be the blank icon
    }

    func testAppList(_ lfc: LockdownClient, type appType: ApplicationType = .any) throws {
        let proxy = try lfc.createInstallationProxy(escrow: true)

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
