/**
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as
 published by the Free Software Foundation, either version 3 of the
 License, or (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
import XCTest
@testable import Busq

class BusqTests: XCTestCase {
    override class func setUp() {
        //MobileDevice.debug = true
    }

    override class func tearDown() {
        //MobileDevice.debug = false
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
            try testFileConduit(lfc)


             try testAppList(lfc)
             try testInstallationProxy(lfc)
             try testSpringboardServiceClient(lfc)
             try testHouseArrestClient(lfc)
             try testSyslogRelayClient(lfc)
            // try testFileRelayClient(lfc) // muxError
            // try testDebugServer(lfc) // seems to require manual start of the service
        }
    }

    #if !os(Windows) // https://bugs.swift.org/browse/SR-15230 is fixed for Linux, but still seems to affect Windows
    #if !targetEnvironment(simulator)
    func testInstallIPA() async throws {
        // this throws an error on Linux, but just returns an empty array on macOS
        let deviceInfos = (try? DeviceManager.getDeviceListExtended()) ?? []

        print("Devices:", deviceInfos.count)
        for deviceInfo in deviceInfos {
            print("device:", deviceInfo.udid, "connectionType:", deviceInfo.connectionType)
            if deviceInfo.connectionType == .network {
                continue // skip wireless connections while testing for efficiency
            }

            // “If identity consists of exactly forty hexadecimal digits, it is instead interpreted as the SHA-1 hash of the certificate part of the desired identity.  In this case, the identity's subject name is not considered.”
            let identity = "2AA218EA1DAF3C2984708FD8985D782BE8DF036C"
            // let identity = "Apple Distribution: … (2HFBY6N8ZN)" // doesn't work
            let teamID = "2HFBY6N8ZN"

            let sourceURL = URL(fileURLWithPath: "/opt/src/ipas/Cloud-Cuckoo-iOS.ipa")

            let device = try Device(udid: deviceInfo.udid, options: deviceInfo.connectionType == .network ? .network : .usbmux)
            let lfc = try device.createLockdownClient()

            // recompressing the zip is slower, but leads to a faster app transfer time, so it is probably worth it
            let recompress: Bool = true

            let now = { Date().timeIntervalSinceReferenceDate }

            let signStart = now()
            let signedIPA = try FileManager.default.prepareIPA(sourceURL, identity: identity, teamID: teamID, recompress: recompress)
            let signEnd = now()
            print("prepareIPA time:", signEnd - signStart) // recompress=true: 17.81 recompress=false: 12.56

            let installStart = now()
            try await lfc.installApp(from: signedIPA)
            let installEnd = now()
            print("sideloadApp time:", installEnd - installStart) // recompress=true: 0.95 recompress=false: 1.37
        }
    }
    #endif
    #endif
    
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

        // /Downloads: [".", "..", "downloads.28.sqlitedb", "downloads.28.sqlitedb-shm", "downloads.28.sqlitedb-wal"]
        print("   - /Downloads:", try client.readDirectory(path: "/Downloads"))
        // /Books: [".", "..", "Managed", ".Books.plist.lock", "Sync", "Purchases"]
        print("   - /Books:", try client.readDirectory(path: "/Books"))
        // /iTunes_Control: [".", "..", "Artwork", "iTunes", "Music"]
        print("   - /iTunes_Control:", try client.readDirectory(path: "/iTunes_Control"))
        // /MediaAnalysis: [".", "..", "mediaanalysis.db", "mediaanalysis.db-wal", "mediaanalysis.db-shm", ".backup"]
        print("   - /MediaAnalysis:", try client.readDirectory(path: "/MediaAnalysis"))
        // /PhotoData: [".", "..", "Caches", "PhotoCloudSharingData", "CPLAssets", "cpl_enabled_marker", "cpl_download_finished_marker", "CPL", "Videos", ".Photos_SUPPORT", "Metadata", "protection", "private", "AlbumsMetadata", "Mutations", "Thumbnails", "FacesMetadata", "CameraMetadata", "Photos.sqlite", "MISC", "Photos.sqlite-wal", "Journals", "Photos.sqlite-shm"]
        print("   - /PhotoData:", try client.readDirectory(path: "/PhotoData"))

        // empty
        // print(" -  /Photos:", try client.readDirectory(path: "/Photos"))
        // print(" -  /Recordings:", try client.readDirectory(path: "/Recordings"))
        // print(" -  /DCIM:", try client.readDirectory(path: "/DCIM"))
        // print(" -  /Purchases:", try client.readDirectory(path: "/Purchases"))

        // non-existant folder should throw AFC_E_OBJECT_NOT_FOUND
        XCTAssertThrowsError(try client.readDirectory(path: "/" + UUID().uuidString))

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
