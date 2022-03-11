import Foundation
import libimobiledevice

/// The entry point to the device list
public struct DeviceManager {
    public enum EventType: UInt32 {
        case add = 1
        case remove = 2
        case paired = 3
    }

    public struct Event {
        public let type: EventType?
        public let udid: String?
        public let connectionType: ConnectionType?
    }

    private init() {
    }

    /// The level of debugging.
    public static var debug: Bool = false {
        didSet {
            idevice_set_debug_level(debug ? 1 : 0)
        }
    }

    /// Register a callback function that will be called when device add/remove events occur.
    public static func eventSubscribe(callback: @escaping (Event) throws -> Void) throws -> Disposable {
        let p = Unmanaged.passRetained(Wrapper(value: callback))

        let rawError = idevice_event_subscribe({ (event, userData) in
            guard let userData = userData,
                let rawEvent = event else {
                return
            }

            let action = Unmanaged<Wrapper<(Event) -> Void>>.fromOpaque(userData).takeUnretainedValue().value
            let event = Event(
                type: EventType(rawValue: .init(coercing: rawEvent.pointee.event.rawValue)),
                udid: String(cString: rawEvent.pointee.udid),
                connectionType: ConnectionType(rawValue: .init(coercing: rawEvent.pointee.conn_type.rawValue))
            )
            action(event)
        }, p.toOpaque())

        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }

        return Dispose {
            p.release()
        }
    }

    /// Release the event callback function that has been registered with idevice_event_subscribe().
    public static func eventUnsubscribe() -> MobileDeviceError? {
        let error = idevice_event_unsubscribe()
        return MobileDeviceError(rawValue: error.rawValue)
    }

    /// Get a list of UDIDs of currently available devices (USBMUX devices only).
    public static func getDeviceList() throws -> [String] {
        var devices: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? = nil
        var count: Int32 = 0
        let rawError = idevice_get_device_list(&devices, &count)
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }

        defer { idevice_device_list_free(devices) }

        let bufferPointer = UnsafeMutableBufferPointer<UnsafeMutablePointer<Int8>?>(start: devices, count: Int(count))
        let idList = bufferPointer.compactMap { $0 }.map { String(cString: $0) }

        return idList
    }

    /// Get a list of currently available devices
    public static func getDeviceListExtended() throws -> [DeviceConnectionInfo] {
        var pdevices: UnsafeMutablePointer<idevice_info_t?>? = nil
        var count: Int32 = 0
        let rawError = idevice_get_device_list_extended(&pdevices, &count)
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let devices = pdevices else {
            throw MobileDeviceError.unknown
        }
        defer { idevice_device_list_extended_free(devices) }

        var list: [DeviceConnectionInfo] = []
        for item in UnsafeMutableBufferPointer<idevice_info_t?>(start: devices, count: Int(count)) {
            guard let item = item else {
                continue
            }
            let udid = String(cString: item.pointee.udid)
            guard let connectionType = ConnectionType(rawValue: .init(coercing: item.pointee.conn_type.rawValue)) else {
                continue
            }

            list.append(DeviceConnectionInfo(udid: udid, connectionType: connectionType))
        }

        return list
    }
}


// MARK: LockdownService

/// Manage device preferences, start services, pairing and activation.
public final class LockdownService {
    let rawValue: lockdownd_service_descriptor_t?

    init(rawValue: lockdownd_service_descriptor_t) {
        self.rawValue = rawValue
    }

    /// Frees memory of a service descriptor as returned by `lockdownd_start_service()`
    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        lockdownd_service_descriptor_free(rawValue)
    }
}

public extension Device {
    /// Creates a LockdownClient to manage device preferences, start services, pairing and activation.
    func createLockdownClient(withHandshake: Bool = true, name: String = UUID().uuidString) throws -> LockdownClient {
        try LockdownClient(device: self, withHandshake: withHandshake, name: name)
    }
}


// MARK: LockdownClient

/// Manage device preferences, start services, pairing and activation.
public final class LockdownClient {
    public let device: Device
    let rawValue: lockdownd_client_t?

    /// Creates a new lockdownd client for the device and starts initial handshake. The handshake consists out of `query_type`, `validate_pair`, `pair` and `start_session` calls. It uses the internal pairing record management.
    ///
    ///  This function does not pair with the device or start a session. This has to be done manually by the caller after the client is created. The device disconnects automatically if the lockdown connection idles for more than 10 seconds. Make sure to call `lockdownd_client_free()` as soon as the connection is no longer needed.
    fileprivate init(device: Device, withHandshake: Bool, name: String) throws {
        self.device = device
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        let rawError: lockdownd_error_t
        var client: lockdownd_client_t? = nil
        if withHandshake {
            rawError = lockdownd_client_new_with_handshake(device, &client, name)
        } else {
            rawError = lockdownd_client_new(device, &client, name)
        }

        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }
        guard client != nil else {
            throw LockdownError.unknown
        }
        self.rawValue = client
    }

    /// Requests to start a service and retrieve it's port on success. Sends the escrow bag from the device's pair record.
    public func getService(identifier: String, withEscroBag: Bool = false) throws -> LockdownService {
        guard let lockdown = self.rawValue else {
            throw LockdownError.deallocated
        }

        var pservice: lockdownd_service_descriptor_t? = nil
        let lockdownError: lockdownd_error_t
        if withEscroBag {
            lockdownError = lockdownd_start_service_with_escrow_bag(lockdown, identifier, &pservice)
        } else {
            lockdownError = lockdownd_start_service(lockdown, identifier, &pservice)
        }
        if let error = LockdownError(rawValue: lockdownError.rawValue) {
            throw error
        }
        guard let rawService = pservice else {
            throw LockdownError.unknown
        }

        return LockdownService(rawValue: rawService)
    }

    /// Requests to start a service and perform the closure.
    public func startService<T>(identifier: String, withEscroBag: Bool = false, body: (LockdownService) throws -> T) throws -> T {
        let service = try getService(identifier: identifier, withEscroBag: withEscroBag)
        return try body(service)
    }

    /// Query the type of the service daemon. Depending on whether the device is queried in normal mode or restore mode, different types will be returned.
    public func getQueryType() throws -> String {
        guard let lockdown = self.rawValue else {
            throw LockdownError.deallocated
        }

        var ptype: UnsafeMutablePointer<Int8>? = nil
        let rawError = lockdownd_query_type(lockdown, &ptype)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let type = ptype else {
            throw LockdownError.unknown
        }
        defer { type.deallocate() }

        return String(cString: type)
    }
}

public extension LockdownClient {
    /// Requests to start a service and retrieve it's port on success. Sends the escrow bag from the device's pair record.
    func getService(service: AppleServiceIdentifier, withEscroBag: Bool = false) throws -> LockdownService {
        return try getService(identifier: service.rawValue, withEscroBag: withEscroBag)
    }

    /// Requests to start a service and perform the closure.
    func startService<T>(service: AppleServiceIdentifier, withEscroBag: Bool = false, body: (LockdownService) throws -> T) throws -> T {
        return try startService(identifier: service.rawValue, withEscroBag: withEscroBag, body: body)
    }
}

public extension LockdownClient {
    /// Creates a new `SpringboardServiceClient`
    func createSpringboardServiceClient(withEscroBag: Bool = true) throws -> SpringboardServiceClient {
        try SpringboardServiceClient(device: device, service: getService(identifier: AppleServiceIdentifier.springboard.rawValue, withEscroBag: withEscroBag))
    }

    /// Creates a new `InstallationProxy`
    func createInstallationProxy(withEscroBag: Bool = true) throws -> InstallationProxy {
        try InstallationProxy(device: device, service: getService(identifier: AppleServiceIdentifier.installationProxy.rawValue, withEscroBag: withEscroBag))
    }

    /// Creates a new `FileConduit`
    func createFileConduit(withEscroBag: Bool = true) throws -> FileConduit {
        try FileConduit(device: device, service: getService(identifier: AppleServiceIdentifier.afc.rawValue, withEscroBag: withEscroBag))
    }

    /// Creates a new `HouseArrestClient`
    func createHouseArrestClient(withEscroBag: Bool = true) throws -> HouseArrestClient {
        try HouseArrestClient(device: device, service: getService(identifier: AppleServiceIdentifier.houseArrest.rawValue, withEscroBag: withEscroBag))
    }

    /// Creates a new `DebugServer`
    func createDebugServer(withEscroBag: Bool = true) throws -> DebugServer {
        try DebugServer(device: device, service: getService(identifier: AppleServiceIdentifier.debugserver.rawValue, withEscroBag: withEscroBag))
    }

    /// Creates a new `SyslogRelayClient`
    func createSyslogRelayClient(withEscroBag: Bool = true) throws -> SyslogRelayClient {
        try SyslogRelayClient(device: device, service: getService(identifier: AppleServiceIdentifier.syslogRelay.rawValue, withEscroBag: withEscroBag))
    }

    /// Creates a new `FileRelayClient`
    func createFileRelayClient(withEscroBag: Bool = true) throws -> FileRelayClient {
        try FileRelayClient(device: device, service: getService(identifier: AppleServiceIdentifier.fileRelay.rawValue, withEscroBag: withEscroBag))
    }
}


/// Accessors for various properties.
extension LockdownClient {
    public var deviceName: String? {
        get throws { try getValue(key: "DeviceName").string }
    }

    public var deviceClass: String? {
        get throws { try getValue(key: "DeviceClass").string }
    }

    public var deviceColor: String? {
        get throws { try getValue(key: "DeviceColor").string }
    }

    public var uniqueDeviceID: String? {
        get throws { try getValue(key: "UniqueDeviceID").string }
    }

    public var productVersion: String? {
        get throws { try getValue(key: "ProductVersion").string }
    }

    public var wiFiAddress: String? {
        get throws { try getValue(key: "WiFiAddress").string }
    }

    public var devicePublicKey: String? {
        get throws { try getValue(key: "DevicePublicKey").string }
    }

    /// A number from 0–100 indicating the estimated battery level
    public var batteryLevel: UInt64? {
        get throws { try getValue(domain: "com.apple.mobile.battery", key: "BatteryCurrentCapacity").uint }
    }

    /// Retrieves a preferences plist using an optional domain and/or key name.
    public func getValue(domain: String? = nil, key: String) throws -> Plist {
        guard let lockdown = self.rawValue else {
            throw LockdownError.deallocated
        }

        var pplist: plist_t? = nil
        let rawError = lockdownd_get_value(lockdown, domain, key, &pplist)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let plist = pplist else {
            throw LockdownError.unknown
        }

        return Plist(rawValue: plist)
    }

    /// Sets a preferences value using a plist and optional by domain and/or key name.
    public func setValue(domain: String, key:String, value: Plist) throws {
        guard let lockdown = self.rawValue else {
            throw LockdownError.deallocated
        }
        guard let value = value.rawValue else {
            throw LockdownError.unknown
        }

        let rawError = lockdownd_set_value(lockdown, domain, key, value)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    /// Removes a preference node by domain and/or key name.
    public func removeValue(domain: String, key: String) throws {
        guard let lockdown = self.rawValue else {
            throw LockdownError.deallocated
        }
        let rawError = lockdownd_remove_value(lockdown, domain, key)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    /// Retrieves the name of the device from lockdownd set by the user.
    public func getName() throws -> String {
        guard let lockdown = self.rawValue else {
            throw LockdownError.deallocated
        }
        var rawName: UnsafeMutablePointer<Int8>? = nil
        let rawError = lockdownd_get_device_name(lockdown, &rawName)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }

        guard let pname = rawName else {
            throw LockdownError.unknown
        }
        defer { pname.deallocate() }
        return String(cString: pname)
    }

    /// Retrieves the name of the device from lockdownd set by the user.
    public func getDeviceUDID() throws -> String {
        guard let lockdown = self.rawValue else {
            throw LockdownError.deallocated
        }
        var pudid: UnsafeMutablePointer<Int8>? = nil
        let rawError = lockdownd_get_device_name(lockdown, &pudid)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }

        guard let udid = pudid else {
            throw LockdownError.unknown
        }
        defer { udid.deallocate() }
        return String(cString: udid)

    }

    /// Closes the lockdownd client session if one is running and frees up the `lockdownd_client` struct.
    public func dealloc() {
        guard let lockdown = self.rawValue else {
            return
        }
        lockdownd_client_free(lockdown)
    }
}



public enum ApplicationType: String {
    case system = "System"
    case user = "User"
    case any = "Any"
    case `internal` = "Internal"
}

/// Services available on iOS devices
public enum AppleServiceIdentifier: String {
    case afc = "com.apple.afc"
    case debugserver = "com.apple.debugserver"
    case diagnosticsRelay = "com.apple.diagnostics_relay"
    case fileRelay = "com.apple.mobile.file_relay"
    case syslogRelay = "com.apple.syslog_relay"
    case heartbeat = "com.apple.mobile.heartbeat"
    case houseArrest = "com.apple.mobile.house_arrest"
    case installationProxy = "com.apple.mobile.installation_proxy"
    case misagent = "com.apple.misagent"
    case mobileImageMounter = "com.apple.mobile.mobile_image_mounter"
    case mobileActivationd = "com.apple.mobileactivationd"
    case mobileBackup = "com.apple.mobilebackup"
    case mobileBackup2 = "com.apple.mobilebackup2"
    case mobileSync = "com.apple.mobileSync"
    case notificationProxy = "com.apple.mobile.notification_proxy"
    case preboard = "com.apple.preboard_service_v2"
    case springboard = "com.apple.springboardservices"
    case screenshot = "com.apple.screenshotr"
    case webInspector = "com.apple.webinspector"
}

public enum ConnectionType: UInt32 {
    case usbmuxd = 1
    case network = 2
}

public struct DeviceConnectionInfo {
    public let udid: String
    public let connectionType: ConnectionType
}


public struct DeviceLookupOptions: OptionSet {
    public static let usbmux = DeviceLookupOptions(rawValue: 1 << 1)
    public static let network = DeviceLookupOptions(rawValue: 1 << 2)
    public static let preferNetwork = DeviceLookupOptions(rawValue: 1 << 3)

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// A device connection handle.
public final class DeviceConnection {
    var rawValue: idevice_connection_t?

    init(rawValue: idevice_connection_t) {
        self.rawValue = rawValue
    }

    init() {
        self.rawValue = nil
    }

    /// Send data to a device via the given connection.
    public func send(data: Data) throws -> UInt32 {
        guard let rawValue = self.rawValue else {
            throw MobileDeviceError.disconnected
        }

        return try data.withUnsafeBytes { (pdata) -> UInt32 in
            var sentBytes: UInt32 = 0
            let pdata = pdata.baseAddress?.bindMemory(to: Int8.self, capacity: data.count)
            let rawError = idevice_connection_send(rawValue, pdata, UInt32(data.count), &sentBytes)
            if let error = MobileDeviceError(rawValue: rawError.rawValue) {
                throw error
            }

            return sentBytes
        }
    }

    /// Receive data from a device via the given connection. This function will return after the given timeout even if no data has been received.
    public func receive(timeout: UInt32? = nil, length: UInt32) throws -> (Data, UInt32) {
        guard let rawValue = self.rawValue else {
            throw MobileDeviceError.disconnected
        }

        let pdata = UnsafeMutablePointer<Int8>.allocate(capacity: Int(length))

        defer { pdata.deallocate() }
        let rawError: idevice_error_t
        var receivedBytes: UInt32 = 0
        if let timeout = timeout {
            rawError = idevice_connection_receive_timeout(rawValue, pdata, length, &receivedBytes, timeout)
        } else {
            rawError = idevice_connection_receive(rawValue, pdata, length, &receivedBytes)
        }

        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }

        return (Data(bytes: pdata, count: Int(receivedBytes)), receivedBytes)
    }

    /// Enables or disables SSL for the given connection.
    public func setSSL(enable: Bool) throws {
        guard let rawValue = self.rawValue else {
            throw MobileDeviceError.disconnected
        }
        if enable {
            idevice_connection_enable_ssl(rawValue)
        } else {
            idevice_connection_disable_ssl(rawValue)
        }
    }

    /// Get the underlying file descriptor for a connection
    public func getFileDescriptor() throws -> Int32 {
        guard let rawValue = self.rawValue else {
            throw MobileDeviceError.disconnected
        }
        var fd: Int32 = 0
        let rawError = idevice_connection_get_fd(rawValue, &fd)
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }

        return fd
    }

    /// Disconnect from the device and clean up the connection structure.
    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        idevice_disconnect(rawValue)
    }
}

public enum MobileDeviceError: Int32, Error {
    case invalidArgument = -1
    case unknown = -2
    case noDevice = -3
    case notEnoughData = -4
    case sslError = -5
    case timeout = -6

    case deallocatedDevice = 100
    case disconnected = 101

    public var localizedDescription: String {
        switch self {
        case .invalidArgument:
            return "invalid argument"
        case .unknown:
            return "unknown"
        case .noDevice:
            return "no device"
        case .notEnoughData:
            return "not enough data"
        case .sslError:
            return "ssl error"
        case .timeout:
            return "timeout"
        case .deallocatedDevice:
            return "deallocated device"
        case .disconnected:
            return "disconnected"

        }
    }
}

// MARK: Device

/// A connection to a device.
public final class Device {
    let rawValue: idevice_t?

    /// Creates an `idevice_t` structure for the device specified by UDID, if the device is available (USBMUX devices only).
    public init(udid: String) throws {
        var dev: idevice_t?
        let rawError = idevice_new(&dev, udid)
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = dev
    }

    /// Creates an `idevice_t` structure for the device specified by UDID, if the device is available, with the given lookup options.
    public init(udid: String, options: DeviceLookupOptions) throws {
        var dev: idevice_t?

        let rawError = idevice_new_with_options(&dev, udid, .init(.init(coercing: options.rawValue)))
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = dev
    }

    /// Set up a connection to the given device.
    public func connect(port: UInt) throws -> DeviceConnection {
        guard let device = self.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        var pconnection: idevice_connection_t? = nil
        let rawError = idevice_connect(device, UInt16(port), &pconnection)
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let connection = pconnection else {
            throw MobileDeviceError.unknown
        }
        let conn = DeviceConnection(rawValue: connection)

        return conn
    }

    /// Gets the handle or (usbmux device id) of the device.
    public func getHandle() throws -> UInt32 {
        guard let rawValue = self.rawValue else {
            throw MobileDeviceError.disconnected
        }
        var handle: UInt32 = 0
        let rawError = idevice_get_handle(rawValue, &handle)

        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }

        return handle
    }

    /// Gets the unique id for the device.
    public func getUDID() throws -> String {
        guard let rawValue = self.rawValue else {
            throw MobileDeviceError.disconnected
        }
        var pudid: UnsafeMutablePointer<Int8>? = nil
        let rawError = idevice_get_udid(rawValue, &pudid)
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }

        guard let udid = pudid else {
            throw MobileDeviceError.unknown
        }
        defer { udid.deallocate() }
        return String(cString: udid)
    }

    /// Cleans up an idevice structure, then frees the structure itself.
    func dealloc() {
        if let rawValue = self.rawValue {
            idevice_free(rawValue)
        }
    }
}

public enum LockdownError: Error {
    case invalidArgument
    case invalidConfiguration
    case plistError
    case pairingFailed
    case sslError
    case dictError
    case receiveTimeout
    case muxError
    case noRunningSession
    case invalidResponse
    case missingKey
    case missingValue
    case getProhibited
    case setProhibited
    case remoteProhibited
    case immutableValue
    case passwordProtected
    case userDeniedPairing
    case pairingDialogResponsePending
    case missingHostID
    case invalidHostID
    case sessionActive
    case sessionInactive
    case missingSessionID
    case invalidSessionID
    case missingService
    case invalidService
    case serviceLimit
    case missingPairRecord
    case savePairRecordFailed
    case invalidPairRecord
    case invalidActivationRecord
    case missingActivationRecord
    case serviceProhibited
    case escrowLocked
    case pairingProhibitedOverThisConnection
    case fmipProtected
    case mcProtected
    case mcChallengeRequired
    case unknown

    case deallocated
    case notStartService

    init?(rawValue: Int32) {
        switch rawValue {
        case 0:
            return nil
        case -1:
            self = .invalidArgument
        case -2:
            self = .invalidConfiguration
        case -3:
            self = .plistError
        case -4:
            self = .pairingFailed
        case -5:
            self = .sslError
        case -6:
            self = .dictError
        case -7:
            self = .receiveTimeout
        case -8:
            self = .muxError
        case -9:
            self = .noRunningSession
        case -10:
            self = .invalidResponse
        case -11:
            self = .missingKey
        case -12:
            self = .missingValue
        case -13:
            self = .getProhibited
        case -14:
            self = .setProhibited
        case -15:
            self = .remoteProhibited
        case -16:
            self = .immutableValue
        case -17:
            self = .passwordProtected
        case -18:
            self = .userDeniedPairing
        case -19:
            self = .pairingDialogResponsePending
        case -20:
            self = .missingHostID
        case -21:
            self = .invalidHostID
        case -22:
            self = .sessionActive
        case -23:
            self = .sessionInactive
        case -24:
            self = .missingSessionID
        case -25:
            self = .invalidSessionID
        case -26:
            self = .missingService
        case -27:
            self = .invalidService
        case -28:
            self = .serviceLimit
        case -29:
            self = .missingPairRecord
        case -30:
            self = .savePairRecordFailed
        case -31:
            self = .invalidPairRecord
        case -32:
            self = .invalidActivationRecord
        case -33:
            self = .missingActivationRecord
        case -34:
            self = .serviceProhibited
        case -35:
            self = .escrowLocked
        case -36:
            self = .pairingProhibitedOverThisConnection
        case -37:
            self = .fmipProtected
        case -38:
            self = .mcProtected
        case -39:
            self = .mcChallengeRequired
        case -256:
            self = .unknown
        case 100:
            self = .deallocated
        default:
            return nil
        }
    }
}

extension LockdownError : LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidArgument:
            return NSLocalizedString("Invalid Argument", comment: "")
        case .invalidConfiguration:
            return NSLocalizedString("Invalid Configuration", comment: "")
        case .plistError:
            return NSLocalizedString("Property List Error", comment: "")
        case .pairingFailed:
            return NSLocalizedString("Pairing Failed", comment: "")
        case .sslError:
            return NSLocalizedString("SSL Error", comment: "")
        case .dictError:
            return NSLocalizedString("Dictionary Error", comment: "")
        case .receiveTimeout:
            return NSLocalizedString("Receive Timeout", comment: "")
        case .muxError:
            return NSLocalizedString("Multiplexing Error", comment: "")
        case .noRunningSession:
            return NSLocalizedString("No Running Session", comment: "")
        case .invalidResponse:
            return NSLocalizedString("Invalid Response", comment: "")
        case .missingKey:
            return NSLocalizedString("Missing Key", comment: "")
        case .missingValue:
            return NSLocalizedString("Missing Value", comment: "")
        case .getProhibited:
            return NSLocalizedString("Get Prohibited", comment: "")
        case .setProhibited:
            return NSLocalizedString("Set Prohibited", comment: "")
        case .remoteProhibited:
            return NSLocalizedString("Remote Prohibited", comment: "")
        case .immutableValue:
            return NSLocalizedString("Immutable Value", comment: "")
        case .passwordProtected:
            return NSLocalizedString("Password Protected", comment: "")
        case .userDeniedPairing:
            return NSLocalizedString("User Denied Pairing", comment: "")
        case .pairingDialogResponsePending:
            return NSLocalizedString("Pairing Dialog Response Pending", comment: "")
        case .missingHostID:
            return NSLocalizedString("Missing Host ID", comment: "")
        case .invalidHostID:
            return NSLocalizedString("Invalid Host ID", comment: "")
        case .sessionActive:
            return NSLocalizedString("Session Active", comment: "")
        case .sessionInactive:
            return NSLocalizedString("Session Inactive", comment: "")
        case .missingSessionID:
            return NSLocalizedString("Missing Session ID", comment: "")
        case .invalidSessionID:
            return NSLocalizedString("Invalid Session ID", comment: "")
        case .missingService:
            return NSLocalizedString("Missing Service", comment: "")
        case .invalidService:
            return NSLocalizedString("Invalid Service", comment: "")
        case .serviceLimit:
            return NSLocalizedString("Service Limit", comment: "")
        case .missingPairRecord:
            return NSLocalizedString("Missing Pair Record", comment: "")
        case .savePairRecordFailed:
            return NSLocalizedString("Save Pair Record Failed", comment: "")
        case .invalidPairRecord:
            return NSLocalizedString("Invalid Pair Record", comment: "")
        case .invalidActivationRecord:
            return NSLocalizedString("Invalid Activation Record", comment: "")
        case .missingActivationRecord:
            return NSLocalizedString("Missing Activation Record", comment: "")
        case .serviceProhibited:
            return NSLocalizedString("Service Prohibited", comment: "")
        case .escrowLocked:
            return NSLocalizedString("Escrow Locked", comment: "")
        case .pairingProhibitedOverThisConnection:
            return NSLocalizedString("Pairing Prohibited Over This Connection", comment: "")
        case .fmipProtected:
            return NSLocalizedString("FMIP Protected", comment: "")
        case .mcProtected:
            return NSLocalizedString("MC Protected", comment: "")
        case .mcChallengeRequired:
            return NSLocalizedString("MC Challenge Required", comment: "")
        case .unknown:
            return NSLocalizedString("Unknown", comment: "")
        case .deallocated:
            return NSLocalizedString("Deallocated", comment: "")
        case .notStartService:
            return NSLocalizedString("Service Not Started", comment: "")
        }
    }
}


// MARK: InstallationProxy


/// Manage applications on a device
public final class InstallationProxy {
    private let rawValue: instproxy_client_t?
    public let device: Device

    init(rawValue: instproxy_client_t, device: Device) {
        self.rawValue = rawValue
        self.device = device
    }

    /// Connects to the `installation_proxy` service on the specified device.
    init(device dev: Device, service: LockdownService) throws {
        guard let device = dev.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        guard let service = service.rawValue else {
            throw LockdownError.notStartService
        }

        var client: instproxy_client_t? = nil
        let rawError = instproxy_client_new(device, service, &client)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }
        guard client != nil else {
            throw InstallationProxyError.unknown
        }

        self.rawValue = client
        self.device = dev
    }

    /// Starts a new `installation_proxy` service on the specified device and connects to it.
    static func start<T>(device dev: Device, label: String, action: (InstallationProxy) throws -> T) throws -> T {
        guard let device = dev.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        var ipc: instproxy_client_t? = nil
        let rawError = instproxy_client_start_service(device, &ipc, label)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let client = ipc else {
            throw InstallationProxyError.unknown
        }

        let proxy = InstallationProxy(rawValue: client, device: dev)
        return try action(proxy)
    }

    /// Gets the name from a command dictionary.
    public static func commandGetName(command: Plist) -> String? {
        var pname: UnsafeMutablePointer<Int8>? = nil
        instproxy_command_get_name(command.rawValue, &pname)

        guard let name = pname else {
            return nil
        }
        defer { name.deallocate() }
        return String(cString: name)
    }

    /// Gets the name from a command dictionary.
    public static func statusGetName(status: Plist) -> String? {
        var pname: UnsafeMutablePointer<Int8>? = nil
        instproxy_command_get_name(status.rawValue, &pname)

        guard let name = pname else {
            return nil
        }
        defer { name.deallocate() }
        return String(cString: name)
    }

    /// Gets error name, code and description from a response if available.
    public static func statusGetError(status: Plist) -> InstallationProxyStatusError? {
        var pname: UnsafeMutablePointer<Int8>? = nil
        var pdescription: UnsafeMutablePointer<Int8>? = nil
        var pcode: UInt64 = 0
        let rawError = instproxy_status_get_error(status.rawValue, &pname, &pdescription, &pcode)
        guard InstallationProxyError(rawValue: rawError.rawValue) != nil else {
            return nil
        }

        var name: String? = nil
        var description: String? = nil

        if let namePointer = pname {
            defer { namePointer.deallocate() }
            name = String(cString: namePointer)
        }
        if let descriptionPointer = pdescription {
            defer { descriptionPointer.deallocate() }
            description = String(cString: descriptionPointer)
        }

        return InstallationProxyStatusError(name: name, description: description, code: pcode)
    }

    /// Gets progress in percentage from a status if available.
    public static func statusGetPercentComplete(status: Plist) -> Int32 {
        var percent: Int32 = 0
        instproxy_status_get_percent_complete(status.rawValue, &percent)

        return percent
    }


    /// List installed applications. This function runs synchronously.
    public func browse(options: Plist) throws -> Plist {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        var presult: plist_t? = nil
        let rawError = instproxy_browse(rawValue, options.rawValue, &presult)
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let result = presult else {
            throw InstallationProxyError.unknown
        }

        return Plist(rawValue: result)
    }

    /// List pages of installed applications in a callback.
    public func browse(options: Plist, callback: @escaping (Plist?, Plist?) -> Void) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))

        let rawError = instproxy_browse_with_callback(rawValue, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }
            let pointer = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = pointer.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
            pointer.release()
        }, userData.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData.release()
            throw error
        }

        return Dispose {
            userData.release()
        }
    }

    /// Lookup information about specific applications from the device.
    public func lookup(appIDs: [String]?, options: Plist) throws -> Plist {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let buffer: UnsafeMutableBufferPointer<UnsafePointer<Int8>?>?
        defer { buffer?.deallocate() }
        //var p = appIDs?.map { $0.utf8CString }
        if let appIDs = appIDs {
            let pbuffer = UnsafeMutableBufferPointer<UnsafePointer<Int8>?>.allocate(capacity: appIDs.count + 1)
            for (i, id) in appIDs.enumerated() {
                pbuffer[i] = id.unsafePointer()
            }
            pbuffer[appIDs.count] = nil
            buffer = pbuffer

        } else {
            buffer = nil
        }

        var presult: plist_t? = nil
        let rawError = instproxy_lookup(rawValue, buffer?.baseAddress, options.rawValue, &presult)
        buffer?.forEach { $0?.deallocate() }
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let result = presult else {
            throw InstallationProxyError.unknown
        }

        return Plist(rawValue: result)
    }

    /// Install an application on the device.
    public func install(pkgPath: String, options: Plist, callback: ( (Plist?, Plist?) -> Void)?) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = callback.flatMap { callback in
            Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        }

        let rawError = instproxy_install(rawValue, pkgPath, options.rawValue, callback == nil ? nil : { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData?.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData?.release()
            throw error
        }

        return Dispose {
            userData?.release()
        }
    }

    /// Upgrade an application on the device. This function is nearly the same as `install`; the difference is that the installation progress on the device is faster if the application is already installed.
    public func upgrade(pkgPath: String, options: Plist, callback: ((Plist?, Plist?) -> Void)?) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = callback.flatMap { callback in
            Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        }
        let rawError = instproxy_upgrade(rawValue, pkgPath, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData?.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData?.release()
            throw error
        }

        return Dispose {
            userData?.release()
        }
    }

    /// Uninstall an application from the device.
    public func uninstall(appID: String, options: Plist, callback: ((Plist?, Plist?) -> Void)?) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = callback.flatMap { callback in
            Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        }
        let rawError = instproxy_uninstall(rawValue, appID, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData?.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData?.release()
            throw error
        }

        return Dispose {
            userData?.release()
        }
    }

    /// List archived applications. This function runs synchronously.
    public func lookupArchives(options: Plist = Plist(dictionary: [:])) throws -> Plist {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        var presult: plist_t? = nil
        let rawError = instproxy_lookup_archives(rawValue, options.rawValue, &presult)
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let result = presult else {
            throw InstallationProxyError.unknown
        }

        return Plist(rawValue: result)
    }

    /// Archive an application on the device. This function tells the device to make an archive of the specified application. This results in the device creating a ZIP archive in the 'ApplicationArchives' directory and uninstalling the application.
    public func archive(appID: String, options: Plist, callback: ((Plist?, Plist?) -> Void)?) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = callback.flatMap { callback in
            Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        }
        let rawError = instproxy_archive(rawValue, appID, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData?.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData?.release()
            throw error
        }

        return Dispose {
            userData?.release()
        }
    }

    /// Restore a previously archived application on the device. This function is the counterpart to `archive`.
    public func restore(appID: String, options: Plist, callback: ((Plist?, Plist?) -> Void)?) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = callback.flatMap { callback in
            Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        }
        let rawError = instproxy_restore(rawValue, appID, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData?.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData?.release()
            throw error
        }

        return Dispose {
            userData?.release()
        }
    }

    /// Removes a previously archived application from the device. This function removes the ZIP archive from the 'ApplicationArchives' directory.
    public func removeArchive(appID: String, options: Plist, callback: ((Plist?, Plist?) -> Void)?) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = callback.flatMap { callback in
            Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        }
        let rawError = instproxy_remove_archive(rawValue, appID, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData?.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData?.release()
            throw error
        }

        return Dispose {
            userData?.release()
        }
    }

    /// Checks a device for certain capabilities.
    public func checkCapabilitiesMatch(capabilities: [String], options: Plist, result: Plist) throws -> Plist {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let buffer = UnsafeMutableBufferPointer<UnsafePointer<Int8>?>.allocate(capacity: capabilities.count + 1)
        defer { buffer.deallocate() }
        for (i, capability) in capabilities.enumerated() {
            buffer[i] = capability.unsafePointer()
        }
        buffer[capabilities.count] = nil

        var presult: plist_t? = nil
        let rawError = instproxy_check_capabilities_match(rawValue, buffer.baseAddress, options.rawValue, &presult)
        buffer.forEach { $0?.deallocate() }
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let result = presult else {
            throw InstallationProxyError.unknown
        }

        return Plist(rawValue: result)
    }

    /// Queries the device for the path of an application.
    public func getPath(for bundleIdentifier: String) throws -> String {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }
        var ppath: UnsafeMutablePointer<Int8>? = nil
        let rawError = instproxy_client_get_path_for_bundle_identifier(rawValue, bundleIdentifier, &ppath)
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let path = ppath else {
            throw InstallationProxyError.unknown
        }
        defer { path.deallocate() }

        return String(cString: path)
    }

    /// Disconnects an `installation_proxy` client from the device and frees up the `installation_proxy` client data.
    func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }

        instproxy_client_free(rawValue)
    }
}

public extension InstallationProxy {
    /// Returns the list of installed apps of the given type
    func getAppList(type appType: ApplicationType) throws -> [InstalledAppInfo] {
        let opts = Plist(dictionary: [
            "ApplicationType": Plist(string: appType.rawValue)
        ])

        let appsPlists = try browse(options: opts)
        return appsPlists.array?.map(InstalledAppInfo.init) ?? []
    }

    /// Returns the list of installed apps of the given type
    @available(*, deprecated, message: "crashes in pointer release")
    func getAppListPages(type appType: ApplicationType, callback: @escaping (InstalledAppInfo) -> ()) throws -> Disposable {
        let opts = Plist(dictionary: [
            "ApplicationType": Plist(string: appType.rawValue)
        ])

        return try browse(options: opts) { p1, p2 in
            if let p1 = p1 {
                callback(InstalledAppInfo(rawValue: p1))
            }
        }
    }

    /// Returns the list of archives
    @available(*, deprecated, message: "seems to always return ERROR: lookup_archives returned -42")
    func getArchivesList() throws -> [InstalledAppInfo] {
        let archivesPlist = try lookupArchives()
        return archivesPlist.array?.map(InstalledAppInfo.init) ?? []
    }
}

extension InstallationProxyClientOptionsKey {
    public var key: String {
        switch self {
        case .skipUninstall:
            return "SkipUninstall"
        case .applicationSinf:
            return "ApplicationSINF"
        case .itunesMetadata:
            return "iTunesMetadata"
        case .returnAttributes:
            return "ReturnAttributes"
        case .applicationType:
            return "ApplicationType"
        }
    }
}



public enum InstallationProxyError: Int32, Error {
    case invalidArgument = -1
    case plistError = -2
    case connectionFailed = -3
    case operationInProgress = -4
    case operationFailed = -5
    case receiveTimeout = -6
    case alreadyArchived = -7
    case apiInternalError = -8
    case applicationAlreadyInstalled = -9
    case applicationMoveFailed = -10
    case applicationSinfCaptureFailed = -11
    case applicationSandboxFailed = -12
    case applicationVerificationFailed = -13
    case archiveDestructionFailed = -14
    case bundleVerificationFailed = -15
    case carrierBundleCopyFailed = -16
    case carrierBundleDirectoryCreationFailed = -17
    case carrierBundleMissingSupportedSims = -18
    case commCenterNotificationFailed = -19
    case containerCreationFailed = -20
    case containerPownFailed = -21
    case containerRemovableFailed = -22
    case embeddedProfileInstallFailed = -23
    case executableTwiddleFailed = -24
    case existenceCheckFailed = -25
    case installMapUpdateFailed = -26
    case manifestCaptureFailed = -27
    case mapGenerationFailed = -28
    case missingBundleExecutable = -29
    case missingBundleIdentifier = -30
    case missingBundlePath = -31
    case missingContainer = -32
    case notificationFailed = -33
    case packageExtractionFailed = -34
    case packageInspectionFailed = -35
    case packageMoveFailed = -36
    case pathConversionFailed = -37
    case restoreContainerFailed = -38
    case seatbeltProfileRemovableFailed = -39
    case stageCreationFailed = -40
    case symlinkFailed = -41
    case unknownCommand = -42
    case itunesARtworkCaptureFailed = -43
    case itunesMetadataCaptureFailed = -44
    case deviceOSVersionTooLow = -45
    case deviceFamilyNotSupported = -46
    case packagePatchFailed = -47
    case incorrectArchitecture = -48
    case pluginCopyFailed = -49
    case breadcrumbFailed = -50
    case breadcrumbUnlockFailed = -51
    case geojsonCaputreFailed = -52
    case newsstandArtworkCaputureFailed = -53
    case missingCommand = -54
    case notEntitled = -55
    case missingPackagePath = -56
    case missingContainerPath = -57
    case missingApplicationIdentifier = -58
    case missingAttributeValue = -59
    case lookupFailed = -60
    case dictionaryCreationFailed = -61
    case installProhibited = -62
    case uninstallProhibited = -63
    case missingBUndleVersion = -64
    case unknown = -256

    case deallocatedClient = 100
}

public struct InstallationProxyStatusError {
    public let name: String?
    public let description: String?
    public let code: UInt64
}

public enum InstallationProxyClientOptionsKey {
    case skipUninstall(Bool)
    case applicationSinf(Plist)
    case itunesMetadata(Plist)
    case returnAttributes(Plist)
    case applicationType(ApplicationType)
}




public final class InstallationProxyOptions {
    let rawValue: plist_t?

    /// Creates a new `client_options` plist.
    init() {
        self.rawValue = instproxy_client_options_new()
    }

    /// Set item identified by key in a `#PLIST_DICT` node. The previous item identified by key will be freed using `#plist_free`. If there is no item for the given key a new item will be inserted.
    public func add(arguments: InstallationProxyClientOptionsKey...) {
        guard let rawValue = self.rawValue else {
            return
        }

        for argument in arguments {
            switch argument {
            case .skipUninstall(let bool):
                plist_dict_set_item(rawValue, argument.key, plist_new_bool(bool ? 1 : 0))
            case .applicationSinf(let plist),
                 .itunesMetadata(let plist),
                 .returnAttributes(let plist):
                plist_dict_set_item(rawValue, argument.key, plist_copy(plist.rawValue))
            case .applicationType(let type):
                plist_dict_set_item(rawValue, argument.key, plist_new_string(type.rawValue))
            }
        }
    }

    /// Create a new root plist type `#PLIST_ARRAY`
    public func setReturnAttributes(arguments: String...) {
        guard let rawValue = self.rawValue else {
            return
        }
        let returnAttributes = plist_new_array()
        for argument in arguments {
            plist_array_append_item(returnAttributes, plist_new_string(argument))
        }

        plist_dict_set_item(rawValue, "ReturnAttributes", returnAttributes)
    }

    /// Frees `client_options` plist.
    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        instproxy_client_options_free(rawValue)
    }
}


// MARK: DebugServer


/// Communicate with debugserver on the device.
public final class DebugServer {
    /// Starts a new debugserver service on the specified device and connects to it.
    static func start<T>(device: Device, label: String, body: (DebugServer) throws -> T) throws -> T {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        
        return try label.withCString({ (label) -> T in
            var pclient: debugserver_client_t? = nil
            let rawError = debugserver_client_start_service(device, &pclient, label)
            if let error = DebugServerError(rawValue: rawError.rawValue) {
                throw error
            }
            guard let client = pclient else {
                throw DebugServerError.unknown
            }
            let server = DebugServer(rawValue: client)
            return try body(server)
        })
    }

    /// Encodes a string into hex notation.
    public static func encodeString(buffer: String) -> Data {
        buffer.withCString { (buffer) -> Data in
            var pencodedBuffer: UnsafeMutablePointer<Int8>? = nil
            var encodedLength: UInt32 = 0
            debugserver_encode_string(buffer, &pencodedBuffer, &encodedLength)
            guard let encodedBuffer = pencodedBuffer else {
                return Data()
            }
            
            let bufferPointer = UnsafeBufferPointer<Int8>(start: encodedBuffer, count: Int(encodedLength))
            defer { bufferPointer.deallocate() }
            return Data(buffer: bufferPointer)
        }
    }
    
    private var rawValue: debugserver_client_t?

    init(rawValue: debugserver_client_t) {
        self.rawValue = rawValue
    }

    /// Connects to the debugserver service on the specified device.
    init(device: Device, service: LockdownService) throws {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        guard let service = service.rawValue else {
            throw LockdownError.notStartService
        }
        
        var client: debugserver_client_t? = nil
        let rawError = debugserver_client_new(device, service, &client)
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
        guard client != nil else {
            throw DebugServerError.unknown
        }
        self.rawValue = client
    }

    /// Sends raw data using the given debugserver service client.
    public func send(data: String, size: UInt32) throws -> UInt32 {
        guard let rawValue = self.rawValue else {
            throw DebugServerError.deallocatedClient
        }
        
        return try data.withCString { (data) -> UInt32 in
            var sent: UInt32 = 0
            let rawError = debugserver_client_send(rawValue, data, size, &sent)
            if let error = DebugServerError(rawValue: rawError.rawValue) {
                throw error
            }
            
            return sent
        }
    }

    /// Receives raw data using the given debugserver client with specified timeout.
    public func receive(size: UInt32, timeout: UInt32? = nil) throws -> (Data, UInt32) {
        guard let rawValue = self.rawValue else {
            throw DebugServerError.deallocatedClient
        }
        
        let data = UnsafeMutablePointer<Int8>.allocate(capacity: 0)
        defer { data.deallocate() }
        var received: UInt32 = 0
        let rawError: debugserver_error_t
        if let timeout = timeout {
            rawError = debugserver_client_receive_with_timeout(rawValue, data, size, &received, timeout)
        } else {
            rawError = debugserver_client_receive(rawValue, data, size, &received)
        }
        
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
        
        let buffer = UnsafeBufferPointer<Int8>(start: data, count: Int(received))
        defer { buffer.deallocate() }
        return (Data(buffer: buffer), received)
    }

    /// Sends a command to the debugserver service.
    public func sendCommand(command: DebugServerCommand) throws -> Data {
        guard let rawValue = self.rawValue else {
            throw DebugServerError.deallocatedClient
        }
        guard let rawCommand = command.rawValue else {
            throw DebugServerError.deallocatedCommand
        }
        
        var presponse: UnsafeMutablePointer<Int8>? = nil
        var responseSize: Int = 0
        let rawError = debugserver_client_send_command(rawValue, rawCommand, &presponse, &responseSize)
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
        
        guard let response = presponse else {
            throw DebugServerError.unknown
        }
        
        let buffer = UnsafeBufferPointer<Int8>(start: response, count: responseSize)
        defer { buffer.deallocate() }
        return Data(buffer: buffer)
    }

    /// Receives and parses response of debugserver service.
    public func receiveResponse() throws -> Data {
        guard let rawValue = self.rawValue else {
            throw DebugServerError.deallocatedClient
        }
        
        var presponse: UnsafeMutablePointer<Int8>? = nil
        var responseSize: Int = 0
        let rawError = debugserver_client_receive_response(rawValue, &presponse, &responseSize)
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
        
        guard let response = presponse else {
            throw DebugServerError.unknown
        }
        
        let buffer = UnsafeBufferPointer<Int8>(start: response, count: responseSize)
        defer { buffer.deallocate() }
        return Data(buffer: buffer)
    }

    /// Controls status of ACK mode when sending commands or receiving responses.
    public func setAckMode(enabled: Bool) throws {
        guard let rawValue = self.rawValue else {
            throw DebugServerError.deallocatedClient
        }
        
        let rawError = debugserver_client_set_ack_mode(rawValue, enabled ? 1 : 0)
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    /// Sets the argv which launches an app.
    public func setARGV(argv: [String]) throws -> String {
        guard let rawValue = self.rawValue else {
            throw DebugServerError.deallocatedClient
        }
        
        let argc = argv.count
        let buffer = UnsafeMutableBufferPointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: argc + 1)
        defer { buffer.deallocate() }
        for (i, argument) in argv.enumerated() {
            buffer[i] = argument.unsafeMutablePointer()
        }
        buffer[argc] = nil
        var presponse: UnsafeMutablePointer<Int8>? = nil
        let rawError = debugserver_client_set_argv(rawValue, Int32(argc), buffer.baseAddress, &presponse)
        buffer.forEach { $0?.deallocate() }
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let response = presponse else {
            throw DebugServerError.unknown
        }
        defer { response.deallocate() }
        
        return String(cString: response)
    }

    /// Adds or sets an environment variable.
    public func setEnvironmentHexEncoded(env: String) throws -> String {
        guard let rawValue = self.rawValue else {
            throw DebugServerError.deallocatedClient
        }
        
        return try env.withCString { (env) -> String in
            var presponse: UnsafeMutablePointer<Int8>? = nil
            let rawError = debugserver_client_set_environment_hex_encoded(rawValue, env, &presponse)
            if let error = DebugServerError(rawValue: rawError.rawValue) {
                throw error
            }
            guard let response = presponse else {
                throw DebugServerError.unknown
            }
            defer { response.deallocate() }
            
            return String(cString: response)
        }
    }

    /// Disconnects a debugserver client from the device and frees up the debugserver client data.
    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        debugserver_client_free(rawValue)
        self.rawValue = nil
    }
}

extension DebugServer {
    /// Receives raw data using the given debugserver client with specified timeout.
    func receiveAll(timeout: UInt32? = nil) throws -> Data {
        let size: UInt32 = 131072
        var buffer = Data()
        
        while(true) {
            let (data, received) = try receive(size: size, timeout: timeout)
            buffer += data
            if received == 0 {
                break
            }
        }

        return buffer
    }
}

public enum DebugServerError: Int32, Error {
    case invalidArgument = -1
    case muxError = -2
    case sslError = -3
    case responseError = -4
    case unknown = -256

    case deallocatedClient = 100
    case deallocatedCommand = 101
}

public final class DebugServerCommand {
    let rawValue: debugserver_command_t?

    init(rawValue: debugserver_command_t) {
        self.rawValue = rawValue
    }

    /// Creates and initializes a new command object.
    init(name: String, arguments: [String]) throws {
        let buffer = UnsafeMutableBufferPointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: arguments.count + 1)
        defer { buffer.deallocate() }
        for (i, argument) in arguments.enumerated() {
            buffer[i] = argument.unsafeMutablePointer()
        }

        buffer[arguments.count] = nil
        var cmd: debugserver_command_t?
        let rawError = debugserver_command_new(name, Int32(arguments.count), buffer.baseAddress, &cmd)
        buffer.forEach { $0?.deallocate() }
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = cmd
        guard rawValue == nil else {
            throw DebugServerError.unknown
        }
    }

    /// Frees memory of command object.
    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        debugserver_command_free(rawValue)
    }
}

// MARK: FileRelayClient

/// Retrieve compressed CPIO archives.
public final class FileRelayClient {
    /// Starts a new `file_relay` service on the specified device and connects to it.
    public static func start<T>(device: Device, label: String, body: (FileRelayClient) throws -> T) throws -> T {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        
        var pclient: file_relay_client_t? = nil
        let rawError = file_relay_client_start_service(device, &pclient, label)
        if let error = FileRelayError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let pointer = pclient else {
            throw FileRelayError.unknown
        }
        let client = FileRelayClient(rawValue: pointer)
        let result = try body(client)
        return result
    }
    
    let rawValue: file_relay_client_t?

    init(rawValue: file_relay_client_t) {
        self.rawValue = rawValue
    }

    /// Connects to the `file_relay` service on the specified device.
    public init(device: Device, service: LockdownService) throws {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        guard let service = service.rawValue else {
            throw LockdownError.notStartService
        }
        
        var fileRelay: file_relay_client_t? = nil
        let rawError = file_relay_client_new(device, service, &fileRelay)
        if let error = FileRelayError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = fileRelay
    }

    /// Request data for the given sources. Calls `file_relay_request_sources_timeout()` with a timeout of 60000 milliseconds (60 seconds).
    public func requestSources(sources: [FileRelayRequestSource], timeout: UInt32? = nil) throws -> DeviceConnection {
        guard let rawValue = self.rawValue else {
            throw FileRelayError.deallocatedClient
        }

        let buffer = UnsafeMutableBufferPointer<UnsafePointer<Int8>?>.allocate(capacity: sources.count + 1)
        defer { buffer.deallocate() }
        for (i, source) in sources.enumerated() {
            buffer[i] = source.rawValue.unsafePointer()
        }
        buffer[sources.count] = nil
        
        let connection = DeviceConnection()
        let rawError: file_relay_error_t
        if let timeout = timeout {
            rawError = file_relay_request_sources_timeout(rawValue, buffer.baseAddress, &connection.rawValue, timeout)
        } else {
            rawError = file_relay_request_sources(rawValue,  buffer.baseAddress,&connection.rawValue)
        }
        buffer.forEach { $0?.deallocate() }
         
        if let error = FileRelayError(rawValue: rawError.rawValue) {
            throw error
        }
        
        return connection
    }

    /// Disconnects a `file_relay` client from the device and frees up the `file_relay` client data.
    public func dealloc() throws {
        guard let rawValue = self.rawValue else {
            return
        }
        let rawError = file_relay_client_free(rawValue)
        if let error = FileRelayError(rawValue: rawError.rawValue) {
            throw error
        }
    }
}


public enum FileRelayError: Int32, Error {
    case invalidArgument = -1
    case plistError = -2
    case muxError = -3
    case invalidSource = -4
    case stagingEmpty = -5
    case permissionDenied = -6
    case unknown = -256

    case deallocatedClient = 100
}

public enum FileRelayRequestSource: String {
    case appleSupport = "AppleSupport"
    case network = "Network"
    case vpn = "VPN"
    case wifi = "Wifi"
    case userDatabases = "UserDatabases"
    case crashReporter = "CrashReporter"
    case tmp = "tmp"
    case systemConfiguration = "SystemConfiguration"
}


// MARK: ScreenshotService

public final class ScreenshotService {
    /// Starts a new screenshotr service on the specified device and connects to it.
    static func start<T>(device: Device, label: String, body: (ScreenshotService) throws -> T) throws -> T {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        
        var pscreenshot: screenshotr_client_t? = nil
        let screenshotError = screenshotr_client_start_service(device, &pscreenshot, label)
        
        if let error = ScreenshotError(rawValue: screenshotError.rawValue) {
            throw error
        }
        guard let screenshot = pscreenshot else {
            throw ScreenshotError.unknown
        }
        
        let service = ScreenshotService(rawValue: screenshot)
        return try body(service)
    }
    
    let rawValue: screenshotr_client_t?
    
    init(rawValue: screenshotr_client_t) {
        self.rawValue = rawValue
    }

    /// Connects to the screenshotr service on the specified device.
    init(device: Device, service: LockdownService) throws {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        guard let service = service.rawValue else {
            throw LockdownError.notStartService
        }

        var client: screenshotr_client_t? = nil
        let rawError = screenshotr_client_new(device, service, &client)
        if let error = ScreenshotError(rawValue: rawError.rawValue) {
            throw error
        }
        guard client != nil else {
            throw ScreenshotError.unknown
        }
        self.rawValue = client
    }

    /// Get a screen shot from the connected device.
    public func takeScreenshot() throws -> Data {
        guard let rawValue = self.rawValue else {
            throw ScreenshotError.deallocatedService
        }
        
        var image: UnsafeMutablePointer<Int8>? = nil
        var size: UInt64 = 0
        
        let rawError = screenshotr_take_screenshot(rawValue, &image, &size)
        if let error = ScreenshotError(rawValue: rawError.rawValue) {
            throw error
        }
        
        let buffer = UnsafeBufferPointer(start: image, count: Int(size))
        defer { buffer.deallocate() }

        return Data(buffer: buffer)
    }
    
    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        screenshotr_client_free(rawValue)
    }
}

public enum SyslogRelayError: Int32, Error {
    case invalidArgument = -1
    case muxError = -2
    case sslError = -3
    case notEnoughData = -4
    case timeout = -5
    case unknown = -256
}


public enum ScreenshotError: Int32, Error {
    case invalidArgument = -1
    case plistError = -2
    case muxError = -3
    case sslError = -4
    case receiveTimeout = -5
    case badVersion = -6
    case unknown = -256

    case deallocatedService = 100
}


// MARK: SyslogRelay

/// Capture the syslog output from a device.
public final class SyslogRelayClient {
    /// Starts a new `syslog_relay` service on the specified device and connects to it.
    public static func startService<T>(device: Device, label: String, body: (SyslogRelayClient) throws -> T) throws -> T {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        
        var pclient: syslog_relay_client_t? = nil
        let rawError = syslog_relay_client_start_service(device, &pclient, label)
        if let error = SyslogRelayError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let pointer = pclient else {
            throw SyslogRelayError.unknown
        }
        let client = SyslogRelayClient(rawValue: pointer)
        let result = try body(client)
        return result
    }
    
    private let rawValue: syslog_relay_client_t?
    
    init(rawValue: syslog_relay_client_t) {
        self.rawValue = rawValue
    }

    /// Connects to the `syslog_relay` service on the specified device.
    public init(device: Device, service: LockdownService) throws {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        guard let service = service.rawValue else {
            throw LockdownError.notStartService
        }
        
        var syslogRelay: syslog_relay_client_t? = nil
        let rawError = syslog_relay_client_new(device, service, &syslogRelay)
        if let error = SyslogRelayError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = syslogRelay
    }

    /// Starts capturing the syslog of the device using a callback.
    public func startCapture(callback: @escaping (Int8) -> Void) throws -> Disposable {
        let p = Unmanaged.passRetained(Wrapper(value: callback))
        
        let rawError = syslog_relay_start_capture(rawValue, { (character, userData) in
            guard let userData = userData else {
                return
            }
            
            let action = Unmanaged<Wrapper<(Int8) -> Void>>.fromOpaque(userData).takeUnretainedValue().value
            action(character)
        }, p.toOpaque())
        
        if let error = SyslogRelayError(rawValue: rawError.rawValue) {
            throw error
        }
        
        return Dispose {
            p.release()
        }
    }

    /// Stops capturing the syslog of the device.
    public func stopCapture() throws {
        let rawError = syslog_relay_stop_capture(rawValue)
        if let error = SyslogRelayError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    /// Receives data using the given `syslog_relay` client with specified timeout.
    public func receive(timeout: UInt32? = nil) throws -> String {
        let data = UnsafeMutablePointer<Int8>.allocate(capacity: Int.max)
        var received: UInt32 = 0
        let rawError: syslog_relay_error_t
        if let timeout = timeout {
            rawError = syslog_relay_receive_with_timeout(rawValue, data, UInt32(Int.max), &received, timeout)
        } else {
            rawError = syslog_relay_receive(rawValue, data, UInt32(Int.max), &received)
        }
        
        if let error = SyslogRelayError(rawValue: rawError.rawValue) {
            throw error
        }
        
        return String(cString: data)
    }

    /// Disconnects a `syslog_relay` client from the device and frees up the `syslog_relay` client data.
    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        syslog_relay_client_free(rawValue)
    }
}

public extension SyslogRelayClient {
    /// Starts capturing the syslog of the device using a callback.
    func startCaptureMessage(callback: @escaping (SyslogMessageSink) -> Void) throws -> Disposable {
        var buffer: [Int8] = []
        var previousMessage: SyslogMessageSink?
        return try startCapture { (character) in
            buffer.append(character)
            guard character == 10 else {
                return
            }
            
            let lineString = String(cString: buffer + [0])
            buffer = []
            guard let data = parseLog(message: lineString) else {
                previousMessage?.message += lineString
                return
            }
            guard let message = previousMessage else {
                previousMessage = data
                return
            }
            previousMessage = data
            callback(message)
        }
    }
}


public struct SyslogMessageSink: CustomStringConvertible {
    public fileprivate(set) var message: String
    public let date: Date
    public let name: String
    public let processInfo: String

    public var description: String {
        return "\(dateFormatter.string(from: date)) \(name) \(processInfo) \(message)"
    }
}


// MARK: SpringboardService

public final class SpringboardServiceClient {

    static func startService<T>(lockdown: LockdownClient, label: String, body: (SpringboardServiceClient) throws -> T) throws -> T {
        guard let lockdown = lockdown.rawValue else {
            throw LockdownError.deallocated
        }
        var pclient: sbservices_client_t? = nil
        let rawError = sbservices_client_start_service(lockdown, &pclient, label)
        if let error = SpringboardError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let client = pclient else {
            throw SpringboardError.unknown
        }
        let sbclient = SpringboardServiceClient(rawValue: client)
        let result = try body(sbclient)
        return result
    }

    private var rawValue: sbservices_client_t?

    init(rawValue: sbservices_client_t) {
        self.rawValue = rawValue
    }

    init(device: Device, service: LockdownService) throws {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        guard let service = service.rawValue else {
            throw LockdownError.notStartService
        }

        var client: sbservices_client_t? = nil
        let rawError = sbservices_client_new(device, service, &client)
        if let error = SpringboardError(rawValue: rawError.rawValue) {
            throw error
        }
        guard client != nil else {
            throw SpringboardError.unknown
        }
        self.rawValue = client
    }

    public func getIconPNGData(bundleIdentifier: String) throws -> Data {
        guard let rawValue = self.rawValue else {
            throw SpringboardError.deallocatedService
        }
        var ppng: UnsafeMutablePointer<Int8>? = nil
        var size: UInt64 = 0
        let rawError = sbservices_get_icon_pngdata(rawValue, bundleIdentifier, &ppng, &size)
        if let error = SpringboardError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let png = ppng else {
            throw SpringboardError.unknown
        }
        let buffer = UnsafeMutableBufferPointer(start: png, count: Int(size))
        defer { buffer.deallocate() }

        return Data(buffer: buffer)
    }

    public func getHomeScreenWallpaperPNGData() throws -> Data {
        guard let rawValue = self.rawValue else {
            throw SpringboardError.deallocatedService
        }
        var ppng: UnsafeMutablePointer<Int8>? = nil
        var size: UInt64 = 0
        let rawError = sbservices_get_home_screen_wallpaper_pngdata(rawValue, &ppng, &size)
        if let error = SpringboardError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let png = ppng else {
            throw SpringboardError.unknown
        }

        let buffer = UnsafeMutableBufferPointer(start: png, count: Int(size))
        defer { buffer.deallocate() }

        return Data(buffer: buffer)
    }

    public func dealloc() throws {
        guard let rawValue = self.rawValue else {
            return
        }

        let rawError = sbservices_client_free(rawValue)
        if let error = SpringboardError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = nil
    }
}


public enum SpringboardError: Int32, Error {
    case invalidArgument = -1
    case plistError = -2
    case connectionFailed = -3
    case unknown = -256

    case deallocatedService = 100
}


// MARK: HouseArrest

public final class HouseArrestClient {

    /// Starts a new `house_arrest` service on the specified device and connects to it.
    public static func startService<T>(device: Device, label: String, body: (HouseArrestClient) throws -> T) throws -> T {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }

        var pclient: house_arrest_client_t? = nil

        let rawError = house_arrest_client_start_service(device, &pclient, label)
        if let error = HouseArrestError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let pointer = pclient else {
            throw HouseArrestError.unknown
        }
        let client = HouseArrestClient(rawValue: pointer)
        let result = try body(client)
        return result
    }

    public var rawValue: house_arrest_client_t?

    init(rawValue: house_arrest_client_t) {
        self.rawValue = rawValue
    }

    /// Connects to the `house_arrest` service on the specified device.
    public init(device: Device, service: LockdownService) throws {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        guard let service = service.rawValue else {
            throw LockdownError.notStartService
        }

        var client: house_arrest_client_t? = nil
        let rawError = house_arrest_client_new(device, service, &client)
        if let error = HouseArrestError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = client
    }

    /// Sends a generic request to the connected `house_arrest` service.
    public func sendRequest(dict: Plist) throws {
        let rawError = house_arrest_send_request(rawValue, dict.rawValue)
        if let error = HouseArrestError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    /// Send a command to the connected `house_arrest` service. Calls `house_arrest_send_request()` internally.
    public func sendCommand(command: String, appid: String) throws {
        let rawError = house_arrest_send_command(rawValue, command, appid)
        if let error = HouseArrestError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    /// Retrieves the result of a previously sent `house_arrest_request_*` request.
    public func getResult() throws -> Plist {
        var presult: plist_t? = nil
        let rawError = house_arrest_get_result(rawValue, &presult)
        if let error = HouseArrestError(rawValue: rawError.rawValue) {
            throw error
        }

        guard let result = presult else {
            throw HouseArrestError.unknown
        }

        return Plist(rawValue: result)
    }

    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        house_arrest_client_free(rawValue)
        self.rawValue = nil
    }
}


public enum HouseArrestError: Int32, Error {
    case invalidArg = -1
    case plistError = -2
    case connFailed = -3
    case invalidMode = -4
    case unknown = -256
}


// MARK: FileConduit

public final class FileConduit {

    /// Starts a new `afc` service on the specified device and connects to it.
    public static func startService<T>(device: Device, label: String, body: (FileConduit) throws -> T) throws -> T {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }

        var pclient: afc_client_t? = nil

        let rawError = afc_client_start_service(device, &pclient, label)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
        guard let pointer = pclient else {
            throw FileConduitError.AFC_E_UNKNOWN_ERROR
        }
        let client = FileConduit(rawValue: pointer)
        let result = try body(client)
        return result
    }

    public var rawValue: afc_client_t?

    init(rawValue: afc_client_t) {
        self.rawValue = rawValue
    }

    /// Connects to the `afc` service on the specified device.
    public init(device: Device, service: LockdownService) throws {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        guard let service = service.rawValue else {
            throw LockdownError.notStartService
        }

        var client: afc_client_t? = nil
        let rawError = afc_client_new(device, service, &client)

        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = client
    }

    /// Connects to the `afc` service on the specified house arrest client.
    public init(houseArrest: HouseArrestClient) throws {
        var client: afc_client_t? = nil
        let rawError = afc_client_new_from_house_arrest_client(houseArrest.rawValue, &client)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = client

    }

    public func getDeviceInfo() throws -> [String] {
        var deviceInformation: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? = nil
        let rawError = afc_get_device_info(rawValue, &deviceInformation)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }

        defer { afc_dictionary_free(deviceInformation) }
        let idList = String.array(point: deviceInformation)
        return idList
    }

    public func readDirectory(path: String) throws -> [String] {
        var directoryInformation: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? = nil
        let rawError = afc_read_directory(rawValue, path,  &directoryInformation)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }

        defer { afc_dictionary_free(directoryInformation) }

        let idList = String.array(point: directoryInformation)
        return idList

    }

    public func getFileInfo(path: String) throws -> [String] {
        var fileInformation: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>? = nil
        let rawError = afc_get_file_info(rawValue, path, &fileInformation)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }

        defer { afc_dictionary_free(fileInformation) }
        let idList = String.array(point: fileInformation)
        return idList
    }

    public func fileOpen(filename: String, fileMode: FileConduitFileMode) throws -> UInt64 {

        var handle: UInt64 = 0

        let rawError = afc_file_open(rawValue, filename, afc_file_mode_t(fileMode.rawValue), &handle)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }

        return handle
    }


    public func fileClose(handle: UInt64) throws {
        let rawError = afc_file_close(rawValue, handle)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func fileLock(handle: UInt64, operation: FileConduitLockOp) throws {
        let rawError = afc_file_lock(rawValue, handle, afc_lock_op_t(operation.rawValue))
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func fileRead(handle: UInt64) throws -> Data {
        var data = Data()
        let length: UInt32 = 10000
        var result = try fileRead(handle: handle, length: length)
        while result.1 > 0 {
            data += result.0
            result = try fileRead(handle: handle, length: length)
        }

        return data
    }

    public func fileRead(handle: UInt64, length: UInt32) throws -> (Data, UInt32) {

        let pdata = UnsafeMutablePointer<Int8>.allocate(capacity: Int(length))
        defer { pdata.deallocate() }

        var bytesRead: UInt32 = 0

        let rawError = afc_file_read(rawValue, handle, pdata, length, &bytesRead)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }

        return (Data(bytes: pdata, count: Int(bytesRead)), bytesRead)
    }

    public func fileWrite(handle: UInt64, data: Data) throws ->UInt32 {

        return try data.withUnsafeBytes({ (pdata) -> UInt32 in

            var bytesWritten: UInt32 = 0
            let pdata = pdata.baseAddress?.bindMemory(to: Int8.self, capacity: data.count)
            let rawError = afc_file_write(rawValue, handle, pdata, UInt32(data.count), &bytesWritten)

            if let error = FileConduitError(rawValue: rawError.rawValue) {
                throw error
            }

            return bytesWritten
        })
    }

    public func fileWrite(handle: UInt64, fileURL: URL, progressHandler: ((Double) -> Void)?) throws {

        let data = try Data(contentsOf: fileURL)
        var total = data.count
        var length = 102400
        var index = 0

        repeat{

            if total < length { length = total }
            total -= length

            let subData = data[index..<(index + length)]
            index = index + length
            _ = try fileWrite(handle: handle, data: subData)
            progressHandler?(Double(index) / Double(data.count))
        } while total > 0
    }

    public func fileSeek(handle: UInt64, offset: Int64, whence: Int32) throws {
        let rawError = afc_file_seek(rawValue, handle, offset, whence)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func fileTell(handle: UInt64) throws -> UInt64 {
        var position: UInt64 = 0

        let rawError = afc_file_tell(rawValue, handle, &position)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }

        return position
    }

    public func fileTruncate(handle: UInt64, newsize: UInt64) throws {
        let rawError = afc_file_truncate(rawValue, handle, newsize)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func removeFile(path: String) throws {
        let rawError = afc_remove_path(rawValue, path)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func renamePath(from: String, to: String) throws {
        let rawError = afc_rename_path(rawValue, from, to)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func makeDirectory(path: String) throws {
        let rawError = afc_make_directory(rawValue, path)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func truncate(path: String, newsize: UInt64) throws {
        let rawError = afc_truncate(rawValue, path, newsize)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func makeLink(linkType: FileConduitLinkType, target: String, linkName: String) throws {
        let rawError = afc_make_link(rawValue, afc_link_type_t(linkType.rawValue), target, linkName)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func setFileTime(path: String, date: Date) throws {
        let rawError = afc_set_file_time(rawValue, path, UInt64(date.timeIntervalSinceReferenceDate))
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func removePathAndContents(path: String) throws {
        let rawError = afc_remove_path_and_contents(rawValue, path)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public func getDeviceInfoKey(key: String) throws -> String? {
        var pvalue: UnsafeMutablePointer<Int8>? = nil
        let rawError = afc_get_device_info_key(rawValue, key, &pvalue)
        if let error = FileConduitError(rawValue: rawError.rawValue) {
            throw error
        }

        guard let value = pvalue else {
            return nil
        }
        defer { value.deallocate() }
        return String(cString: value)
    }

    public func dealloc() {
        guard let rawValue = self.rawValue else {
            return
        }
        afc_client_free(rawValue)
        self.rawValue = nil
    }
}

public enum FileConduitFileMode: UInt32 {
    case rdOnly = 0x00000001
    case rw = 0x00000002
    case wrOnly = 0x00000003
    case wr = 0x00000004
    case append = 0x00000005
    case rdAppend = 0x00000006
}

public enum FileConduitLinkType: UInt32 {
    case hardLink = 1
    case symLink = 2
}

public enum FileConduitLockOp: UInt32 {
    case sh = 5
    case ex = 6
    case un = 12
}


public enum FileConduitError: Int32, Error {
    // case AFC_E_SUCCESS               =  0 // not an error
    case AFC_E_UNKNOWN_ERROR         =  1
    case AFC_E_OP_HEADER_INVALID     =  2
    case AFC_E_NO_RESOURCES          =  3
    case AFC_E_READ_ERROR            =  4
    case AFC_E_WRITE_ERROR           =  5
    case AFC_E_UNKNOWN_PACKET_TYPE   =  6
    case AFC_E_INVALID_ARG           =  7
    case AFC_E_OBJECT_NOT_FOUND      =  8
    case AFC_E_OBJECT_IS_DIR         =  9
    case AFC_E_PERM_DENIED           = 10
    case AFC_E_SERVICE_NOT_CONNECTED = 11
    case AFC_E_OP_TIMEOUT            = 12
    case AFC_E_TOO_MUCH_DATA         = 13
    case AFC_E_END_OF_DATA           = 14
    case AFC_E_OP_NOT_SUPPORTED      = 15
    case AFC_E_OBJECT_EXISTS         = 16
    case AFC_E_OBJECT_BUSY           = 17
    case AFC_E_NO_SPACE_LEFT         = 18
    case AFC_E_OP_WOULD_BLOCK        = 19
    case AFC_E_IO_ERROR              = 20
    case AFC_E_OP_INTERRUPTED        = 21
    case AFC_E_OP_IN_PROGRESS        = 22
    case AFC_E_INTERNAL_ERROR        = 23
    case AFC_E_MUX_ERROR             = 30
    case AFC_E_NO_MEM                = 31
    case AFC_E_NOT_ENOUGH_DATA       = 32
    case AFC_E_DIR_NOT_EMPTY         = 33
    case AFC_E_FORCE_SIGNED_TYPE     = -1
}



// MARK: Miscellanea

class Wrapper<T> {
    let value: T
    init(value: T) {
        self.value = value
    }
}

public protocol Disposable {
    func dispose()
}

struct Dispose: Disposable {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func dispose() {
        self.action()
    }
}


extension String {
    init(errorNumber: Int32) {
        guard let code = POSIXErrorCode(rawValue: errorNumber) else {
            self = "unknown"
            return
        }

        let error = POSIXError(code)

        self = "\(error.code.rawValue  ): \(error.localizedDescription)"
    }
}


private extension String {
    func unsafeMutablePointer() -> UnsafeMutablePointer<Int8>? {
        let cString = utf8CString
        let buffer = UnsafeMutableBufferPointer<Int8>.allocate(capacity: cString.count)
        _ = buffer.initialize(from: cString)

        return buffer.baseAddress
    }

    func unsafePointer() -> UnsafePointer<Int8>? {
        return UnsafePointer<Int8>(unsafeMutablePointer())
    }

    static func array(point: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> [String] {
        var count = 0
        var p = point?[count]
        while p != nil {
            count += 1
            p = point?[count]
        }

        let bufferPointer = UnsafeMutableBufferPointer<UnsafeMutablePointer<Int8>?>(start: point, count: count)
        let list = bufferPointer.compactMap { $0 }.map { String(cString: $0) }

        return list
    }
}


private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM dd HH:mm:ss"
    return formatter
}()


private func parseLog(message: String) -> SyslogMessageSink? {
    let data = message.split(separator: " ")
    guard data.count > 5 else {
        return nil
    }
    let dateString = data[0..<3].joined(separator: " ")
    guard let date = dateFormatter.date(from: dateString) else {
        return nil
    }
    let name = data[3]
    let processInfo = data[4]

    return SyslogMessageSink(
        message: String(data[5...].joined(separator: " ")),
        date: date,
        name: String(name),
        processInfo: String(processInfo)
    )
}


/// A representation of an app installed on a device
public struct InstalledAppInfo {
    public let rawValue: Plist
    public let dict: [String: Plist]

    public init(rawValue: Plist) {
        self.rawValue = rawValue

        let keyValues = rawValue.dictionary?.map { kv in
            (kv.key, kv.value)
        } ?? []

        self.dict = Dictionary(keyValues, uniquingKeysWith: { $1 })

    }
}

public extension InstalledAppInfo {
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

private extension UInt32 {
    /// Shim for importing various uint32/int32 on Windows vs. others
    init(coercing value: Int32) {
        self.init(value)
    }

    /// Shim for importing various uint32/int32 on Windows vs. others
    init(coercing value: UInt32) {
        self.init(value)
    }
}

private extension Int32 {
    /// Shim for importing various uint32/int32 on Windows vs. others
    init(coercing value: Int32) {
        self.init(value)
    }

    /// Shim for importing various uint32/int32 on Windows vs. others
    init(coercing value: UInt32) {
        self.init(value)
    }
}

