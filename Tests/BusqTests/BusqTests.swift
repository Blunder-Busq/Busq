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

extension FileManager {
    /// Exracts the .ipa zip file at the given URL and signs it with the specified identity, using entitlements for the given teamID.
    /// - Parameters:
    ///   - url: the path of the .ipa to sign
    ///   - identity: the signing identity, either the keychain name, or the SHA-256 of the certificate to use
    ///   - teamID: the team identifier for signing
    ///   - recompress: whether to re-zip the files after signing or just return the extracted URL
    /// - Returns: the resulting signed artifact
    public func signIPA(_ url: URL, identity: String, teamID: String, recompress: Bool) async throws -> URL {
        #if !os(macOS)
        throw CocoaError(.featureUnsupported) // no NSUserUnixTask on other platforms
        #else
        let baseDir = URL(fileURLWithPath: UUID().uuidString, isDirectory: true, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory()))

        let outputDir = URL(fileURLWithPath: url.lastPathComponent, isDirectory: true, relativeTo: baseDir)
        try self.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)

        print("extracting ipa to:", outputDir.path)

        // extract the file
        try await NSUserUnixTask(url: URL(fileURLWithPath: "/usr/bin/unzip")).execute(withArguments: ["-o", "-q", url.path, "-d", outputDir.path])

        try await signFolder(outputDir, identity: identity, teamID: teamID)

        if !recompress {
            // just upload the output folder directly
            return outputDir
        } else {
            // repackage as an IPA so we can just send a single file
            // surprisingly, this seems to be slower than sending the expanded ipa directly
            let repackaged = url.deletingPathExtension().appendingPathExtension("signed.ipa")
            print("re-packaging signed ipa to:", repackaged.path)

            // zip cannot trim path components unless it is in the current directoy;
            // so we need to create a bogus script and execute that instead
            let script = """
            #!/bin/sh
            cd '\(outputDir.path)'
            /usr/bin/zip -ru '\(repackaged.path)' Payload
            """

            let zipScript = URL(fileURLWithPath: UUID().uuidString, isDirectory: true, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathExtension("sh")
            try script.write(to: zipScript, atomically: true, encoding: .utf8)
            try self.setAttributes([.posixPermissions: NSNumber(value: 0o777)], ofItemAtPath: zipScript.path)

            print("zipScript:", zipScript.path)
            try await NSUserUnixTask(url: URL(fileURLWithPath: zipScript.path)).execute(withArguments: [])
            return repackaged
        }
        #endif
    }

    /// Codesigns the nested `.app` and `.framework` folders in the given directory.
    ///
    /// - Parameters:
    ///   - outputDir: the folder to scan
    ///   - identity: the identity to pass to the `codesign` tool, which must be available in the keychain
    ///   - teamID: the team ID for signing
    ///   - keychain: the keychain name to use (optional)
    ///   - verify: whether to verify the code signatures after signing
    ///   - overwrite: whether to overrite any signature that may exist; otherwise, an error will occur if the code is already signed
    func signFolder(_ outputDir: URL, identity: String, teamID: String, keychain: String? = nil, verify: Bool = true, overwrite: Bool = true) async throws {
        #if !os(macOS)
        throw CocoaError(.featureUnsupported) // no NSUserUnixTask on other platforms
        #else
        // get the "Payload" subfolder
        guard let pathEnumerator = self.enumerator(at: outputDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles, errorHandler: { url, error in
            print("error enumerating:", url, error)
            return true
        }) else {
            throw CocoaError(.fileReadUnknown)
        }

        // Get the list of framework and app paths to sign, starting from the shallowest to the depeest
        let signPaths = Array(pathEnumerator)
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "app" || $0.pathExtension == "framework" }
            .sorted(by: { $0.pathComponents.count < $1.pathComponents.count })

        // get the root app path
        guard let appPath = signPaths.first, appPath.pathExtension == "app" else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        // extract the bundle ID from the app's Info.plist so we can set it in the entitlement
        let plistData = try Data(contentsOf: URL(fileURLWithPath: "Info.plist", relativeTo: appPath))
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? NSDictionary else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let appid = plist["CFBundleIdentifier"] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let xcent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>application-identifier</key>
            <string>\(teamID).\(appid)</string>
            <key>com.apple.developer.team-identifier</key>
            <string>\(teamID)</string>
            <key>get-task-allow</key>
            <true/>
            <key>keychain-access-groups</key>
            <array>
                <string>\(teamID).\(appid)</string>
            </array>
        </dict>
        </plist>
        """

        let entitlementsDir = URL(fileURLWithPath: UUID().uuidString, isDirectory: true, relativeTo: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        try createDirectory(at: entitlementsDir, withIntermediateDirectories: true)

        let xcentPath = URL(fileURLWithPath: "entitlements.xcent", isDirectory: false, relativeTo: entitlementsDir)

        try xcent.write(to: xcentPath, atomically: false, encoding: .utf8)


        // Iterate through the reverse apps/frameworks paths (i.e., start with the deepest), since signing a child after a parent will invalidate the parent's signature: “If your app contains nested code, such as an app extension, a framework, or a bundled watchOS app, sign each item separately, starting with the most deeply nested executable, and working your way out; then sign your main app last. Don’t include entitlements or profiles when signing frameworks. Including them produces an invalid code signature.”
        for signPath in signPaths.reversed() {

            // sign the code
            print("signing:", signPath.path)

            var args = [
                "--sign", identity,
                "--timestamp=none",
                "--generate-entitlement-der"
            ]

            if signPath.pathExtension == "app" {
                // args += ["--preserve-metadata=identifier,entitlements,flags"]
            } else if signPath.pathExtension == "framework" {
            }

            args += ["--entitlements", xcentPath.path]

            if let keychain = keychain {
                args += ["--keychain", keychain]
            }

            if overwrite {
                args += ["--force"]
            }

            args += ["--strict"]

            args += [signPath.path]

            try await NSUserUnixTask(url: URL(fileURLWithPath: "/usr/bin/codesign")).execute(withArguments: args)
        }

        if verify {
            for signPath in signPaths { // verify all
                var verifyArgs = ["-vvvv", "--verify"]
                verifyArgs += ["--strict"]
                verifyArgs += ["--deep"]
                verifyArgs += ["--display"]

                verifyArgs += [signPath.path]

                try await NSUserUnixTask(url: URL(fileURLWithPath: "/usr/bin/codesign")).execute(withArguments: verifyArgs)
            }
        }
        #endif
    }

}


