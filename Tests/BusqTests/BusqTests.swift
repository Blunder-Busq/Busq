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
            var service = try lfc.getService(identifier: AppleServiceIdentifier.installationProxy.rawValue, withEscroBag: false)
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
                for appInfo in appPlists.map(InstalledAppInfo.init) {
                    print(" - app:", appInfo.CFBundleIdentifier ?? "", "name:", appInfo.CFBundleDisplayName ?? "", "version:", appInfo.CFBundleShortVersionString ?? "") // , "keys:", appInfo.dict.keys.sorted())
                }
            }
        }
    }
}

struct InstalledAppInfo : RawRepresentable {
    let rawValue: Plist
    let dict: [String: Plist]

    init(rawValue: Plist) {
        self.rawValue = rawValue

        let keyValues = rawValue.dictionary?.map { kv in
            (kv.key, kv.value)
        } ?? []

        self.dict = Dictionary(keyValues, uniquingKeysWith: { $1 })

    }
}

extension InstalledAppInfo {
    var CFBundleIdentifier: String? { dict["CFBundleIdentifier"]?.string }
    var CFBundleDevelopmentRegion: String? { dict["CFBundleDevelopmentRegion"]?.string }
    var CFBundleDisplayName: String? { dict["CFBundleDisplayName"]?.string }
    var CFBundleExecutable: String? { dict["CFBundleExecutable"]?.string }
    var CFBundleName: String? { dict["CFBundleName"]?.string }
    var ApplicationType: String? { dict["ApplicationType"]?.string }
    var CFBundleShortVersionString: String? { dict["CFBundleShortVersionString"]?.string }
    var CFBundleVersion: String? { dict["CFBundleVersion"]?.string }

    /// E.g.: `/private/var/containers/Bundle/Application/<UUID>/Music.app`
    var Path: String? { dict["Path"]?.string }

    /// E.g.: `Apple iPhone OS Application Signing` or `TestFlight Beta Distribution`
    var SignerIdentity: String? { dict["SignerIdentity"]?.string }

    var IsDemotedApp: Bool? { dict["IsDemotedApp"]?.bool }
    var IsHostBackupEligible: Bool? { dict["IsHostBackupEligible"]?.bool }
    var IsUpgradeable: Bool? { dict["IsUpgradeable"]?.bool }
    var IsAppClip: Bool? { dict["IsAppClip"]?.bool }
}

/// UsageDescription keys
extension InstalledAppInfo {
    var NSAppleEventsUsageDescription: String? { dict["NSAppleEventsUsageDescription"]?.string }
    var NSBluetoothUsageDescription: String? { dict["NSBluetoothUsageDescription"]?.string }
    var NSLocationAlwaysUsageDescription: String? { dict["NSLocationAlwaysUsageDescription"]?.string }
    var NSVideoSubscriberAccountUsageDescription: String? { dict["NSVideoSubscriberAccountUsageDescription"]?.string }
    var NSFocusStatusUsageDescription: String? { dict["NSFocusStatusUsageDescription"]?.string }
    var NFCReaderUsageDescription: String? { dict["NFCReaderUsageDescription"]?.string }
    var NSHomeKitUsageDescription: String? { dict["NSHomeKitUsageDescription"]?.string }
    var NSRemindersUsageDescription: String? { dict["NSRemindersUsageDescription"]?.string }
    var NSLocationTemporaryUsageDescriptionDictionary: String? { dict["NSLocationTemporaryUsageDescriptionDictionary"]?.string }
    var NSSiriUsageDescription: String? { dict["NSSiriUsageDescription"]?.string }
    var NSHealthShareUsageDescription: String? { dict["NSHealthShareUsageDescription"]?.string }
    var NSHealthUpdateUsageDescription: String? { dict["NSHealthUpdateUsageDescription"]?.string }
    var NSSpeechRecognitionUsageDescription: String? { dict["NSSpeechRecognitionUsageDescription"]?.string }
    var NSLocationUsageDescription: String? { dict["NSLocationUsageDescription"]?.string }
    var NSMotionUsageDescription: String? { dict["NSMotionUsageDescription"]?.string }
    var NSLocalNetworkUsageDescription: String? { dict["NSLocalNetworkUsageDescription"]?.string }
    var NSAppleMusicUsageDescription: String? { dict["NSAppleMusicUsageDescription"]?.string }
    var NSLocationAlwaysAndWhenInUseUsageDescription: String? { dict["NSLocationAlwaysAndWhenInUseUsageDescription"]?.string }
    var NSUserTrackingUsageDescription: String? { dict["NSUserTrackingUsageDescription"]?.string }
    var NSBluetoothAlwaysUsageDescription: String? { dict["NSBluetoothAlwaysUsageDescription"]?.string }
    var NSFaceIDUsageDescription: String? { dict["NSFaceIDUsageDescription"]?.string }
    var NSBluetoothPeripheralUsageDescription: String? { dict["NSBluetoothPeripheralUsageDescription"]?.string }
    var NSCalendarsUsageDescription: String? { dict["NSCalendarsUsageDescription"]?.string }
    var NSContactsUsageDescription: String? { dict["NSContactsUsageDescription"]?.string }
    var NSMicrophoneUsageDescription: String? { dict["NSMicrophoneUsageDescription"]?.string }
    var NSPhotoLibraryAddUsageDescription: String? { dict["NSPhotoLibraryAddUsageDescription"]?.string }
    var NSPhotoLibraryUsageDescription: String? { dict["NSPhotoLibraryUsageDescription"]?.string }
    var NSCameraUsageDescription: String? { dict["NSCameraUsageDescription"]?.string }
    var NSLocationWhenInUseUsageDescription: String? { dict["NSLocationWhenInUseUsageDescription"]?.string }
}

