/**
 Copyright The Blunder Busq Contributors
 SPDX-License-Identifier: AGPL-3.0

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
import Busq
import Foundation
import ArgumentParser

/// A tool to interface with an iOS device.
@main struct BusqTool: ParsableCommand {
    static var configuration = CommandConfiguration(commandName: "busq",
        abstract: "A utility for interfacing with iOS devices.",
        subcommands: [
            ListDevices.self,
            ListFolder.self,
            Concatinate.self,
            RemoveFile.self,
            RemoveFolder.self,
            CreateFolder.self,
            TransmitFile.self,
            ReceiveFile.self,
            InstallApp.self,
            UninstallApp.self,
            ArchiveApp.self,
            ListApps.self,
        ])

    struct Options: ParsableArguments {
        @Option(name: [.long, .customShort("u")], help: "restrict devices to specified udid(s).")
        var udids: [String] = []

        @Flag(name: [.long, .customShort("j")], help: "output as JSON.")
        var json = false

        @Flag(name: [.long, .customShort("J")], help: "output as pretty JSON.")
        var jsonPretty = false

        @Flag(name: [.long, .customShort("e")], inversion: .prefixedNo, help: "use escrow.")
        var escrow = false

        /// Query the connected device infos, returning a list that is (optionally) filtered by the `-u` flag.
        /// - Returns: the list of devices seen on the network, ordered first by USB then Wifi devices.
        func getDeviceInfos() throws -> [DeviceConnectionInfo] {
            let deviceInfos = try DeviceManager.getDeviceListExtended()

            // when we are connected both by network and USB, prefer the USB connection
            let wiredUDIDs = deviceInfos.filter({ $0.connectionType == .usbmuxd}).map(\.udid)

            func connectionTypeName(_ type: ConnectionType) -> String {
                switch type {
                case .network: return "network"
                case .usbmuxd: return "usb"
                }
            }

            var devInfos: [DeviceConnectionInfo] = []
            for deviceInfo in deviceInfos {
                if !self.udids.isEmpty && !self.udids.contains(deviceInfo.udid) {
                    continue
                }

                if deviceInfo.connectionType == .network && wiredUDIDs.contains(deviceInfo.udid) {
                    // when we have the same device on both network and USB, just show the USB one
                    continue
                }

                devInfos.append(deviceInfo)
            }

            // sort connected first
            return devInfos.sorted { i1, i2 in
                i1.connectionType.rawValue < i2.connectionType.rawValue
            }
        }

        func show(_ results: [String], header: String? = nil) throws {
            if json || jsonPretty {
                try print(serializeJSON(results))
            } else {
                if let header = header {
                    print(header)
                }
                for result in results {
                    print(result)
                }
            }
        }

        func show(_ results: [[String: String]], header: String? = nil, primaryKey: String? = nil) throws {
            if json || jsonPretty {
                try print(serializeJSON(results))
            } else {
                if let header = header {
                    print(header)
                }
                for result in results {
                    var keys = Set(result.keys)
                    if let primaryKey = primaryKey, keys.remove(primaryKey) != nil {
                        print(primaryKey + ":", result[primaryKey] ?? "")
                    }

                    for key in keys.sorted() {
                        print("  ", key + ":", result[key] ?? "")
                    }
                }
            }
        }

        /// Serialize the output to JSON
        func serializeJSON<T: Encodable>(_ value: T) throws -> String {
            var opts = JSONEncoder.OutputFormatting()
            opts.insert(.withoutEscapingSlashes)
            opts.insert(.sortedKeys)
            if jsonPretty {
                opts.insert(.prettyPrinted)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = opts
            encoder.dataEncodingStrategy = .base64
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? ""
        }

        /// Creates a `FileConduit` and runs the given block with each of the arguments
        func runFileCommand<T>(_ args: [String], firstDeviceOnly: Bool = true, block: (FileConduit, String) throws -> T) throws -> [T] {
            var results: [T] = []
            for deviceInfo in try self.getDeviceInfos() {
                let device = try deviceInfo.createDevice()
                let client = try device.createLockdownClient()
                let conduit = try client.createFileConduit(escrow: escrow)
                for arg in args {
                    let result = try block(conduit, arg)
                    results.append(result)
                }
                if firstDeviceOnly {
                    break // only connect to the first device
                }
            }

            return results
        }
    }

    /// Uploads the given URL to the specified remote path with the file conduit.
    /// - Parameters:
    ///   - url: the local file URL to transfer
    ///   - remotePath: the remote file path the store the file; the parent folder must already exist
    ///   - conduit: the FileConduit to use
    ///   - progress: if true, show a progress bar in standard error
    ///   - overwrite: if true, overwrite an existing file if it already exists
    static func transmit(_ url: URL, to remotePath: String, conduit: FileConduit, progress: Bool, overwrite: Bool) throws {
        if overwrite == false {
            let destinationFileExists: Bool
            do {
                // attempt to open and close the file; if it exists, and we do not want to overwrite, the fail if it was successful
                try conduit.fileClose(handle: conduit.fileOpen(filename: remotePath, fileMode: .rdOnly))
                destinationFileExists = true
            } catch {
                // expected that it should fail if there is no such file
                destinationFileExists = false
            }
            if destinationFileExists {
                throw CocoaError(.fileWriteFileExists) // cannot overwrite
            }
        }

        if progress {
            //print("Sending:", url.path, "to:", remotePath) // , "on:", try conduit.getDeviceInfo())
        }

        let handle = try conduit.fileOpen(filename: remotePath, fileMode: .wrOnly)
        defer { try? conduit.fileClose(handle: handle) }
        let progressBar = progress ? ProgressBar(output: FileHandle.standardError) : nil
        let info = url.lastPathComponent
        try conduit.fileWrite(handle: handle, fileURL: url) { p in
            progressBar?.displayProgress(count: Int(p * 1000), total: 1000, info: info)
        }
        if progress {
            print("") // finish progress view
        }
    }

    struct ListDevices: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "list", abstract: "List available devices.")

        @OptionGroup var options: BusqTool.Options

        @Flag(name: [.long, .customShort("b")], help: "brief output.")
        var brief = false

        @Option(name: [.long, .customShort("p")], help: "device property to display.")
        var property: [String] = [
            "DeviceName",
            "DeviceClass",
            "ProductName",
            "ProductType",
            "ProductVersion",
            "ModelNumber",
            "PasswordProtected",
            "BuildVersion",
            "ChipID",
            "FirmwareVersion",
            "HardwarePlatform",
            "SerialNumber",
            "UniqueChipID",
            "UniqueDeviceID",
            "WifiVendor",
        ].sorted()

        mutating func run() throws {
            var results: [[String: String]] = []

            for deviceInfo in try options.getDeviceInfos() {
                var result: [String: String] = [
                    "UniqueDeviceID": deviceInfo.udid,
                    //"Connection Type": connectionTypeName(deviceInfo.connectionType)
                ]
                if self.brief == false {
                    let device = try deviceInfo.createDevice()
                    let client = try device.createLockdownClient()
                    for deviceKey in property {
                        if let value = (try? client.getValue(domain: nil, key: deviceKey)) {
                            result[deviceKey] = valueDescription(value)
                        }
                    }
                }
                results.append(result)
            }

            try options.show(results, header: "Device list:", primaryKey: "UniqueDeviceID")
        }
    }

    struct ListApps: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "apps", abstract: "List installed apps.")

        @OptionGroup var options: BusqTool.Options

        @Option(name: [.long, .customShort("t")], help: "the app type (System, User, Any).")
        var type: String = "User"

        mutating func run() throws {
            // var appList: [String: [String]] = [:] // TODO: JSON output

            for deviceInfo in try options.getDeviceInfos() {
                let device = try deviceInfo.createDevice()
                let client = try device.createLockdownClient()
                let iproxy = try client.createInstallationProxy(escrow: options.escrow)

                let opts = Plist(dictionary: [
                    "ApplicationType": Plist(string: type)
                ])

                let apps = try iproxy.browse(options: opts)
                let iapps = apps.array?.map(InstalledAppInfo.init) ?? []

                // appList[deviceInfo.udid] = apps
                for app in iapps {
                    if let appid = app.CFBundleIdentifier {
                        print(appid)
                    }
                }
            }

        }
    }


    /// List the contents of one or more folders in an iOS device.
    struct ListFolder: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "ls", abstract: "List directory contents.")

        @OptionGroup var options: BusqTool.Options

        @Argument(help: "The folder(s) to query.")
        var folders: [String]

        mutating func run() throws {
            let results = try options.runFileCommand(folders) { conduit, arg in
                try conduit.readDirectory(path: arg)
                    .filter { path in
                        path != "." && path != ".." // skip current/parent folder specifiers
                    }
            }
            let folderResults = zip(folders, results)
            if options.json || options.jsonPretty {
                // output data as base-64 encoded map
                let dict = Dictionary(folderResults) { $1 }
                try print(options.serializeJSON(dict))
            } else {
                for (folder, contents) in folderResults {
                    print(folder)
                    for content in contents {
                        print(" ", content)
                    }
                }
            }
        }
    }

    struct RemoveFolder: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "rmdir", abstract: "Remove folder and contents.")

        @OptionGroup var options: BusqTool.Options

        @Argument(help: "The folder(s) to delete.")
        var folders: [String]

        mutating func run() throws {
            let _ = try options.runFileCommand(folders) { conduit, arg in
                try conduit.removePathAndContents(path: arg)
            }
        }
    }

    struct CreateFolder: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "mkdir", abstract: "Make directories.")

        @OptionGroup var options: BusqTool.Options

        @Argument(help: "The folder(s) to create.")
        var folders: [String]

        mutating func run() throws {
            let _ = try options.runFileCommand(folders) { conduit, arg in
                try conduit.makeDirectory(path: arg)
            }
        }
    }

    struct TransmitFile: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "transmit", abstract: "Copy file(s) to device.")

        @OptionGroup var options: BusqTool.Options

        @Flag(name: [.long, .customShort("f")], help: "overwrite existing file(s).")
        var overwrite = false

        @Flag(name: [.long, .customShort("p")], help: "show file transfer progress.")
        var progress = false

        // TODO
        //@Flag(name: [.long, .customShort("r")], help: "Copy subfolders recursively.")
        //var recursive = false

        @Option(name: [.long, .customShort("d")], help: "the destination folder on the device.")
        var directory: String

        @Argument(help: "The file(s) to upload to the device.")
        var files: [String]

        mutating func run() throws {
            let _ = try options.runFileCommand(files) { conduit, arg in
                let url = URL(fileURLWithPath: arg)
                let remotePath = directory + "/" + url.lastPathComponent
                try transmit(url, to: remotePath, conduit: conduit, progress: progress, overwrite: overwrite)
            }
        }
    }


    struct ReceiveFile: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "receive", abstract: "Copy file(s) from device.")

        @OptionGroup var options: BusqTool.Options

        @Flag(name: [.long, .customShort("f")], help: "overwrite existing file(s).")
        var overwrite = false

        @Flag(name: [.long, .customShort("p")], help: "show file transfer progress.")
        var progress = false

        // TODO
        //@Flag(name: [.long, .customShort("r")], help: "Copy subfolders recursively.")
        //var recursive = false

        @Option(name: [.long, .customShort("d")], help: "the local directory to store file(s).")
        var directory: String = "."

        @Argument(help: "The file(s) to download from the device.")
        var files: [String]

        mutating func run() throws {
            let _ = try options.runFileCommand(files) { conduit, arg in
                let argPath = URL(fileURLWithPath: arg)
                let localPath = URL(fileURLWithPath: argPath.lastPathComponent, isDirectory: false, relativeTo: URL(fileURLWithPath: directory, isDirectory: true))

                if overwrite == false {
                    if FileManager.default.fileExists(atPath: localPath.path) {
                        throw CocoaError(.fileWriteFileExists) // cannot overwrite
                    }
                }

                if progress {
                    print("Receiving:", localPath.path, "from:", arg)
                }

                let handle = try conduit.fileOpen(filename: arg, fileMode: .rdOnly)
                defer { try? conduit.fileClose(handle: handle) }

                // TODO: support streaming to file handle and progress
//                let progressBar = self.progress ? ProgressBar(output: FileHandle.standardError) : nil
//                let info = argPath.lastPathComponent
//                try conduit.fileRead(handle: handle) { p in
//                    progressBar?.displayProgress(count: Int(p * 1000), total: 1000, info: info)
//                }
//                if self.progress {
//                    print("") // finish progress view
//                }

                let data = try conduit.fileRead(handle: handle)
                try data.write(to: localPath)
            }
        }
    }


    struct RemoveFile: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "rm", abstract: "Remove directory entries.")

        @OptionGroup var options: BusqTool.Options

        @Argument(help: "The file(s) to delete.")
        var folders: [String]

        mutating func run() throws {
            let _ = try options.runFileCommand(folders) { conduit, arg in
                try conduit.removePathAndContents(path: arg)
            }
        }
    }

    struct Concatinate: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "cat", abstract: "Concatenate and print files.")

        @OptionGroup var options: BusqTool.Options

        @Argument(help: "The files to print.")
        var files: [String]

        mutating func run() throws {
            let datas: [Data] = try options.runFileCommand(files) { conduit, file in
                let handle = try conduit.fileOpen(filename: file, fileMode: .rdOnly)
                defer { try? conduit.fileClose(handle: handle) }
                let data = try conduit.fileRead(handle: handle)
                return data
            }

            if options.json || options.jsonPretty {
                // output data as base-64 encoded map
                let dict = Dictionary(zip(files, datas)) { $1 }
                try print(options.serializeJSON(dict))
            } else {
                for data in datas {
                    // write the raw data to the terminal
                    try FileHandle.standardOutput.write(contentsOf: data)
                }
            }
        }
    }

    struct UninstallApp: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "uninstall", abstract: "Uninstalls app(s) from device.")

        @OptionGroup var options: BusqTool.Options

        var firstDeviceOnly = true

        @Argument(help: "The app bundle ID(s) to uninstall.")
        var bundleIDs: [String]

        mutating func run() throws {
            for deviceInfo in try options.getDeviceInfos() {
                let device = try deviceInfo.createDevice()
                let client = try device.createLockdownClient()
                let iproxy = try client.createInstallationProxy(escrow: options.escrow)
                for bundleID in bundleIDs {
                    let _ = try iproxy.uninstall(appID: bundleID, options: Plist(dictionary: [:]), callback: nil)
                }
                if firstDeviceOnly {
                    break // only connect to the first device
                }
            }
        }
    }

    struct ArchiveApp: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "archive", abstract: "Archive app(s) on device.")

        @OptionGroup var options: BusqTool.Options

        var firstDeviceOnly = true

        @Flag(name: [.long, .customShort("s")], inversion: .prefixedNo, help: "skip uninstall.")
        var skipUninstall = false

        @Option(name: [.long, .customShort("a")], help: "archive type.")
        var archiveType: String = "ApplicationOnly"

        @Argument(help: "The app bundle ID(s) to archive.")
        var bundleIDs: [String]

        mutating func run() throws {
            // The client options to use, as PLIST_DICT, or NULL. Valid options include: "SkipUninstall" -> Boolean "ArchiveType" -> "ApplicationOnly"
            var opts: [String : Plist] = [:]
            opts["SkipUninstall"] = Plist(bool: skipUninstall)
            opts["ArchiveType"] = Plist(string: archiveType)


            for deviceInfo in try options.getDeviceInfos() {
                let device = try deviceInfo.createDevice()
                let client = try device.createLockdownClient()
                let iproxy = try client.createInstallationProxy(escrow: options.escrow)
                for bundleID in bundleIDs {
                    let _ = try iproxy.archive(appID: bundleID, options: Plist(dictionary: opts), callback: nil)
                }
                if firstDeviceOnly {
                    break // only connect to the first device
                }
            }
        }
    }

    struct InstallApp: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "install", abstract: "Install app(s) from remote ipa.")

        @OptionGroup var options: BusqTool.Options

        var firstDeviceOnly = true

        @Flag(name: [.long, .customShort("D")], inversion: .prefixedNo, help: "install as developer package.")
        var developer = true

        @Flag(name: [.long, .customShort("x")], inversion: .prefixedNo, help: "skip transmit (assumes pe-existing remote path).")
        var skipTransmit = false

        @Flag(name: [.long, .customShort("U")], help: "upgrade installed app.")
        var upgrade = false

        @Flag(name: [.long, .customShort("p")], help: "show file transfer progress.")
        var progress = false

        @Argument(help: "The ipa file(s) to install.")
        var ipa: [String]

        mutating func run() throws {
            var opts: [String : Plist] = [:]
            if developer {
                opts["PackageType"] = Plist(string: "Developer")
            }

            let optsDict = Plist(dictionary: opts)
            for deviceInfo in try options.getDeviceInfos() {
                let device = try deviceInfo.createDevice()
                let client = try device.createLockdownClient()
                let iproxy = try client.createInstallationProxy(escrow: options.escrow)
                let conduit = try client.createFileConduit(escrow: options.escrow)

                for arg in ipa {
                    var installPath = arg
                    if skipTransmit == false {
                        // first transmit the files to the remote location
                        let argPath = URL(fileURLWithPath: arg)
                        let dir = "/busq"
                        try? conduit.makeDirectory(path: dir)
                        installPath = dir + "/" + argPath.lastPathComponent
                        try transmit(argPath, to: installPath, conduit: conduit, progress: progress, overwrite: true)
                    }

                    if upgrade {
                        let _ = try iproxy.upgrade(pkgPath: installPath, options: optsDict, callback: nil)
                    } else {
                        let _ = try iproxy.install(pkgPath: installPath, options: optsDict, callback: nil)
                    }
                }
                if firstDeviceOnly {
                    break // only connect to the first device
                }
            }
        }
    }


    static func valueDescription(_ plist: Plist) -> String? {
        switch plist.nodeType {
        case .boolean:
            return plist.bool?.description
        case .uint:
            return plist.uint?.description
        case .real:
            return plist.real?.description
        case .string:
            return plist.string?.description
        case .date:
            return plist.date?.description
        case .data:
            return plist.data?.description
        case .key:
            return plist.key
        case .uid:
            return plist.uid?.description
        case .array:
            return "array"
        case .dict:
            return "dictionary"
        case .none:
            return "none"
        }
    }
}

protocol OutputBuffer {
    func write(_ text: String)
    func clearLine()
}

class StringBuffer: OutputBuffer {
    private(set) var string: String = ""

    func write(_ text: String) {
        string.append(text)
    }

    func clearLine() {
        string = ""
    }
}

extension FileHandle: OutputBuffer {
    func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        write(data)
    }

    func clearLine() {
        write("\r")
    }
}

public struct ProgressBar {
    private var output: OutputBuffer
    public let progressWidth: Int = 40 // TODO: auto-detect?
    let barChar = "🁢"
    let tickChar = "-"

    init(output: OutputBuffer) {
        self.output = output
        self.output.write("")
    }

    /// Renders the given progress amount with the specified info
    /// - Parameters:
    ///   - count: the current count
    ///   - total: the total count
    ///   - info: additional info to display
    func displayProgress(count: Int, total: Int, info: String? = nil) {
        let progress = Float(count) / Float(total)
        let numberOfBars = Int(floor(progress * Float(progressWidth)))
        let numberOfTicks = progressWidth - numberOfBars
        let bars = String(repeating: barChar, count: numberOfBars)
        let ticks = String(repeating: tickChar, count: numberOfTicks)

        var percentage = Int(floor(progress * 100)).description
        while percentage.count < 3 {
            percentage = " " + percentage
        }

        // truncate info to fit in the terminal width
        var infoPart = Array(info ?? "")
        while infoPart.count > 35 {
            infoPart.remove(at: infoPart.count / 2)
        }
        if infoPart.count != info?.count {
            // insert truncation ellipses
            infoPart.insert(contentsOf: "…", at: infoPart.count / 2)
        }

        output.clearLine()
        output.write("[\(bars)\(ticks)] \(percentage)% \(String(infoPart))")
    }
}
