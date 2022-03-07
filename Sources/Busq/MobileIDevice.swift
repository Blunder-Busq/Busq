import Foundation
import libimobiledevice

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM dd HH:mm:ss"
    return formatter
}()

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


public enum ConnectionType: UInt32 {
    case usbmuxd = 1
    case network = 2
}

public struct DeviceInfo {
    public let udid: String
    public let connectionType: ConnectionType
}

public struct MobileDevice {
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

    public static var debug: Bool = false {
        didSet {
            idevice_set_debug_level(debug ? 1 : 0)
        }
    }

    public static func eventSubscribe(callback: @escaping (Event) throws -> Void) throws -> Disposable {
        let p = Unmanaged.passRetained(Wrapper(value: callback))

        let rawError = idevice_event_subscribe({ (event, userData) in
            guard let userData = userData,
                let rawEvent = event else {
                return
            }

            let action = Unmanaged<Wrapper<(Event) -> Void>>.fromOpaque(userData).takeUnretainedValue().value
            let event = Event(
                type: EventType(rawValue: rawEvent.pointee.event.rawValue),
                udid: String(cString: rawEvent.pointee.udid),
                connectionType: ConnectionType(rawValue: rawEvent.pointee.conn_type.rawValue)
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

    public static func eventUnsubscribe() -> MobileDeviceError? {
        let error = idevice_event_unsubscribe()
        return MobileDeviceError(rawValue: error.rawValue)
    }

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

    public static func getDeviceListExtended() throws -> [DeviceInfo] {
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

        var list: [DeviceInfo] = []
        for item in UnsafeMutableBufferPointer<idevice_info_t?>(start: devices, count: Int(count)) {
            guard let item = item else {
                continue
            }
            let udid = String(cString: item.pointee.udid)
            guard let connectionType = ConnectionType(rawValue: item.pointee.conn_type.rawValue) else {
                continue
            }

            list.append(DeviceInfo(udid: udid, connectionType: connectionType))
        }

        return list
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

public struct DeviceLookupOptions: OptionSet {
    public static let usbmux = DeviceLookupOptions(rawValue: 1 << 1)
    public static let network = DeviceLookupOptions(rawValue: 1 << 2)
    public static let preferNetwork = DeviceLookupOptions(rawValue: 1 << 3)

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}


public class NativeDeviceConnection {
    private let connection: InternalNativeDeviceConnection

    init(sock: Int32) {
        connection = InternalNativeDeviceConnection(sock: sock)
    }

    public func start() throws {
        try connection.start()
    }

    public func send(data: Data) {
        connection.send(data: data)
    }

    public func receive(callback: @escaping (Data) -> Void) {
        connection.outputCallback = callback
    }
}

private let bufferSize = 1024
private class InternalNativeDeviceConnection: NSObject, StreamDelegate {
    private let sock: Int32
    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    var outputCallback: ((Data) -> Void)?

    init(sock: Int32) {
        self.sock = sock
    }

    func start() throws {
        self.receive()
    }

    func receive() {
        while true {
            var buffer = Data()
            var bytes = [CChar](repeating: 0, count: bufferSize)
            while true {
                let recvBytes = recv(sock, &bytes, bufferSize, 0)
                guard recvBytes > -1 else {
                    print("recv error: \(String(errorNumber: errno))")
                    return
                }
                switch recvBytes {
                case 0:
                    return
                case bufferSize:
                    buffer += Data(bytes: &bytes, count: bufferSize)
                    continue
                default:
                    buffer += Data(bytes: &bytes, count: recvBytes)
                    break
                }
                break
            }

            self.outputCallback?(buffer)
        }
    }

    func send(data: Data) {
        var data = [UInt8](data)
        Darwin.send(sock, &data, data.count, 0)
    }
}


public struct DeviceConnection {
    var rawValue: idevice_connection_t?

    init(rawValue: idevice_connection_t) {
        self.rawValue = rawValue
    }

    init() {
        self.rawValue = nil
    }

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

    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        idevice_disconnect(rawValue)
        self.rawValue = nil
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

public struct Device {
    var rawValue: idevice_t? = nil

    public init(udid: String) throws {
        let rawError = idevice_new(&rawValue, udid)
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }
    }

    public init(udid: String, options: DeviceLookupOptions) throws {
        let rawError = idevice_new_with_options(&rawValue, udid, .init(options.rawValue))
        if let error = MobileDeviceError(rawValue: rawError.rawValue) {
            throw error
        }
    }

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

    public mutating func free() {
        if let rawValue = self.rawValue {
            idevice_free(rawValue)
            self.rawValue = nil
        }
    }
}

public enum LockdownError: Error {
    case invalidArgument
    case invalidConfiguration
    case plistError
    case paireingFailed
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
    case userDeniedPaireing
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
    case invlidActivationRecord
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
            self = .paireingFailed
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
            self = .userDeniedPaireing
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
            self = .invlidActivationRecord
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

public enum ApplicationType: String {
    case system = "System"
    case user = "User"
    case any = "Any"
    case `internal` = "Internal"
}


public enum InstallationProxyClientOptionsKey {
    case skipUninstall(Bool)
    case applicationSinf(Plist)
    case itunesMetadata(Plist)
    case returnAttributes(Plist)
    case applicationType(ApplicationType)
}




public struct InstallationProxyOptions {
    var rawValue: plist_t?

    init() {
        self.rawValue = instproxy_client_options_new()
    }

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

    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        instproxy_client_options_free(rawValue)
        self.rawValue = nil
    }
}

public struct InstallationProxy {
    static func start<T>(device: Device, label: String, action: (InstallationProxy) throws -> T) throws -> T {
        guard let device = device.rawValue else {
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

        var proxy = InstallationProxy(rawValue: client)
        defer { proxy.free() }

        return try action(InstallationProxy(rawValue: client))
    }

    public static func commandGetName(command: Plist) -> String? {
        var pname: UnsafeMutablePointer<Int8>? = nil
        instproxy_command_get_name(command.rawValue, &pname)

        guard let name = pname else {
            return nil
        }
        defer { name.deallocate() }
        return String(cString: name)
    }

    public static func statusGetName(status: Plist) -> String? {
        var pname: UnsafeMutablePointer<Int8>? = nil
        instproxy_command_get_name(status.rawValue, &pname)

        guard let name = pname else {
            return nil
        }
        defer { name.deallocate() }
        return String(cString: name)
    }

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

//    public static func statusGetCurrentList(status: Plist) {
//        // TODO
//    }

    public static func statusGetPercentComplete(status: Plist) -> Int32 {
        var percent: Int32 = 0
        instproxy_status_get_percent_complete(status.rawValue, &percent)

        return percent
    }

    private var rawValue: instproxy_client_t?

    init(rawValue: instproxy_client_t) {
        self.rawValue = rawValue
    }

    init(device: Device, service: LockdownService) throws {
        guard let device = device.rawValue else {
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
    }

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

    public func lookup(appIDs: [String]?, options: Plist) throws -> Plist {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let buffer: UnsafeMutableBufferPointer<UnsafePointer<Int8>?>?
        defer { buffer?.deallocate() }
        var p = appIDs?.map { $0.utf8CString }
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

    public func install(pkgPath: String, options: Plist, callback: @escaping (Plist?, Plist?) -> Void) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        let rawError = instproxy_install(rawValue, pkgPath, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData.release()
            throw error
        }

        return Dispose {
            userData.release()
        }
    }

    public func upgrade(pkgPath: String, options: Plist, callback: @escaping (Plist?, Plist?) -> Void) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        let rawError = instproxy_upgrade(rawValue, pkgPath, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData.release()
            throw error
        }

        return Dispose {
            userData.release()
        }
    }

    public func uninstall(appID: String, options: Plist, callback: @escaping (Plist?, Plist?) -> Void) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        let rawError = instproxy_uninstall(rawValue, appID, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData.release()
            throw error
        }

        return Dispose {
            userData.release()
        }
    }

    public func lookupArchives(options: Plist) throws -> Plist {
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

    public func archive(appID: String, options: Plist, callback: @escaping (Plist?, Plist?) -> Void) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        let rawError = instproxy_archive(rawValue, appID, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData.release()
            throw error
        }

        return Dispose {
            userData.release()
        }
    }

    public func restore(appID: String, options: Plist, callback: @escaping (Plist?, Plist?) -> Void) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        let rawError = instproxy_restore(rawValue, appID, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData.release()
            throw error
        }

        return Dispose {
            userData.release()
        }
    }

    public func removeArchive(appID: String, options: Plist, callback: @escaping (Plist?, Plist?) -> Void) throws -> Disposable {
        guard let rawValue = self.rawValue else {
            throw InstallationProxyError.deallocatedClient
        }

        let userData = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.passRetained(Wrapper(value: callback))
        let rawError = instproxy_remove_archive(rawValue, appID, options.rawValue, { (command, status, userData) in
            guard let userData = userData else {
                return
            }

            let wrapper = Unmanaged<Wrapper<(Plist?, Plist?) -> Void>>.fromOpaque(userData)
            let callback = wrapper.takeUnretainedValue().value
            callback(Plist(nillableValue: command), Plist(nillableValue: status))
        }, userData.toOpaque())
        if let error = InstallationProxyError(rawValue: rawError.rawValue) {
            userData.release()
            throw error
        }

        return Dispose {
            userData.release()
        }
    }

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

    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }

        instproxy_client_free(rawValue)
        self.rawValue = nil
    }
}





public struct LockdownService {
    var rawValue: lockdownd_service_descriptor_t?

    init(rawValue: lockdownd_service_descriptor_t) {
        self.rawValue = rawValue
    }

    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        lockdownd_service_descriptor_free(rawValue)
        self.rawValue = nil
    }
}

public struct LockdownClient {
    var rawValue: lockdownd_client_t?

    public init(device: Device, withHandshake: Bool, name: String = UUID().uuidString) throws {
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

    public func startService<T>(identifier: String, withEscroBag: Bool = false, body: (LockdownService) throws -> T) throws -> T {
        var service = try getService(identifier: identifier, withEscroBag: withEscroBag)
        defer { service.free() }
        return try body(service)
    }

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

    public func getValue(domain: String, key: String) throws -> Plist {
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

    public func removeValue(domain: String, key: String) throws {
        guard let lockdown = self.rawValue else {
            throw LockdownError.deallocated
        }
        let rawError = lockdownd_remove_value(lockdown, domain, key)
        if let error = LockdownError(rawValue: rawError.rawValue) {
            throw error
        }
    }

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

    public mutating func free() {
        guard let lockdown = self.rawValue else {
            return
        }
        lockdownd_client_free(lockdown)
        self.rawValue = nil
    }
}


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
    case springboar = "com.apple.springboardservices"
    case screenshot = "com.apple.screenshotr"
    case webInspector = "com.apple.webinspector"
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

public struct DebugServerCommand {
    var rawValue: debugserver_command_t?
    
    init(rawValue: debugserver_command_t) {
        self.rawValue = rawValue
    }
    
    init(name: String, arguments: [String]) throws {
        let buffer = UnsafeMutableBufferPointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: arguments.count + 1)
        defer { buffer.deallocate() }
        for (i, argument) in arguments.enumerated() {
            buffer[i] = argument.unsafeMutablePointer()
        }

        buffer[arguments.count] = nil
        let rawError = debugserver_command_new(name, Int32(arguments.count), buffer.baseAddress, &rawValue)
        buffer.forEach { $0?.deallocate() }
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
        guard rawValue == nil else {
            throw DebugServerError.unknown
        }
    }
    
    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        debugserver_command_free(rawValue)
        self.rawValue = nil
    }
}

public struct DebugServer {
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
            var server = DebugServer(rawValue: client)
            defer { server.free() }
            
            return try body(server)
        })
    }
    
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
    
    public func setAckMode(enabled: Bool) throws {
        guard let rawValue = self.rawValue else {
            throw DebugServerError.deallocatedClient
        }
        
        let rawError = debugserver_client_set_ack_mode(rawValue, enabled ? 1 : 0)
        if let error = DebugServerError(rawValue: rawError.rawValue) {
            throw error
        }
    }
    
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
    
    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        debugserver_client_free(rawValue)
        self.rawValue = nil
    }
}

extension DebugServer {
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

public struct FileRelayClient {
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
        var client = FileRelayClient(rawValue: pointer)
        let result = try body(client)
        try client.free()
        return result
    }
    
    var rawValue: file_relay_client_t?

    init(rawValue: file_relay_client_t) {
        self.rawValue = rawValue
    }
    
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
        
        var connection = DeviceConnection()
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
    
    public mutating func free() throws {
        guard let rawValue = self.rawValue else {
            return
        }
        let rawError = file_relay_client_free(rawValue)
        if let error = FileRelayError(rawValue: rawError.rawValue) {
            throw error
        }
        self.rawValue = nil
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




public extension LockdownClient {
    func getService(service: AppleServiceIdentifier, withEscroBag: Bool = false) throws -> LockdownService {
        return try getService(service: service, withEscroBag: withEscroBag)
    }
    
    func startService<T>(service: AppleServiceIdentifier, withEscroBag: Bool = false, body: (LockdownService) throws -> T) throws -> T {
        return try startService(identifier: service.rawValue, withEscroBag: withEscroBag, body: body)
    }
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


public struct ScreenshotService {
    static func start<T>(device: Device, label: String, body: (ScreenshotService) throws -> T) throws -> T {
        guard let device = device.rawValue else {
            throw MobileDeviceError.deallocatedDevice
        }
        
        var pscreenshot: screenshotr_client_t? = nil
        var screenshotError = screenshotr_client_start_service(device, &pscreenshot, label)
        
        if let error = ScreenshotError(rawValue: screenshotError.rawValue) {
            throw error
        }
        guard let screenshot = pscreenshot else {
            throw ScreenshotError.unknown
        }
        
        var service = ScreenshotService(rawValue: screenshot)
        defer { service.free() }
        return try body(service)
    }
    
    var rawValue: screenshotr_client_t?
    
    init(rawValue: screenshotr_client_t) {
        self.rawValue = rawValue
    }
    
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
    
    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        screenshotr_client_free(rawValue)
        self.rawValue = nil
    }
}



extension String {
    func unsafeMutablePointer() -> UnsafeMutablePointer<Int8>? {
        let cString = utf8CString
        let buffer = UnsafeMutableBufferPointer<Int8>.allocate(capacity: cString.count)
        _ = buffer.initialize(from: cString)
        
        return buffer.baseAddress
    }
    
    func unsafePointer() -> UnsafePointer<Int8>? {
        return UnsafePointer<Int8>(unsafeMutablePointer())
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

public struct SyslogReceivedData: CustomStringConvertible {
    public fileprivate(set) var message: String
    public let date: Date
    public let name: String
    public let processInfo: String
    
    public var description: String {
        return "\(dateFormatter.string(from: date)) \(name) \(processInfo) \(message)"
    }
}

public struct SyslogRelayClient {
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
        var client = SyslogRelayClient(rawValue: pointer)
        let result = try body(client)
        try client.free()
        return result
    }
    
    private var rawValue: syslog_relay_client_t?
    
    init(rawValue: syslog_relay_client_t) {
        self.rawValue = rawValue
    }
    
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
    
    public func stopCapture() throws {
        let rawError = syslog_relay_stop_capture(rawValue)
        if let error = SyslogRelayError(rawValue: rawError.rawValue) {
            throw error
        }
    }
    
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
    
    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        syslog_relay_client_free(rawValue)
        self.rawValue = nil
    }
}

public extension SyslogRelayClient {
    func startCaptureMessage(callback: @escaping (SyslogReceivedData) -> Void) throws -> Disposable {
        var buffer: [Int8] = []
        var previousMessage: SyslogReceivedData?
        return try startCapture { (character) in
            buffer.append(character)
            guard character == 10 else {
                return
            }
            
            let lineString = String(cString: buffer + [0])
            buffer = []
            guard let data = tryParseMessage(message: lineString) else {
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


private func tryParseMessage(message: String) -> SyslogReceivedData? {
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

    return SyslogReceivedData(
        message: String(data[5...].joined(separator: " ")),
        date: date,
        name: String(name),
        processInfo: String(processInfo)
    )
}
