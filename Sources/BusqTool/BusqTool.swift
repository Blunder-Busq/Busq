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
import Busq
import Foundation
import ArgumentParser

@main
struct Busq: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "A utility for interfacing with iOS devices.",
        subcommands: [List.self, Ls.self, Cat.self])

    struct Options: ParsableArguments {
        @Option(name: [.long, .customShort("u")], help: "restrict results to specified udid(s).")
        var udids: [String] = []

        @Flag(name: [.long, .customShort("j")], help: "output as JSON.")
        var json = false

        @Flag(name: [.long, .customShort("b")], help: "brief output.")
        var brief = false

        @Flag(name: [.long, .customShort("e")], help: "use escrow.")
        var escrow = false

        /// Query the connected device infos, returning a list that is (optionally) filtered by the `-u` flag.
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

            return devInfos
        }

        func show(_ results: [String], header: String? = nil) throws {
            if json {
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
            if json {
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

        func serializeJSON<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    static func format(_ result: Int, usingHex: Bool) -> String {
        usingHex ? String(result, radix: 16)
            : String(result)
    }


    struct List: ParsableCommand {
        static var configuration
            = CommandConfiguration(abstract: "List available devices.")

        @OptionGroup var options: Busq.Options

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
                if options.brief == false {
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

    struct Ls: ParsableCommand {
        static var configuration
            = CommandConfiguration(abstract: "List device files.")

        @OptionGroup var options: Busq.Options

        @Argument(help: "The folder to query.")
        var folders: [String]

        mutating func run() throws {
            var results: [String] = []
            for deviceInfo in try options.getDeviceInfos() {
                let device = try deviceInfo.createDevice()
                let client = try device.createLockdownClient()
                let conduit = try client.createFileConduit(escrow: options.escrow)
                for folder in folders {
                    let result = try conduit.readDirectory(path: folder)
                    results.append(contentsOf: result)
                }
                break // only connect to the first device
            }

            try options.show(results)
        }
    }

    struct Cat: ParsableCommand {
        static var configuration
            = CommandConfiguration(abstract: "Concatenate and print files.")

        @OptionGroup var options: Busq.Options

        @Argument(help: "The files to print.")
        var files: [String]

        mutating func run() throws {
            //var results: [String] = []
            for deviceInfo in try options.getDeviceInfos() {
                let device = try deviceInfo.createDevice()
                let client = try device.createLockdownClient()
                let conduit = try client.createFileConduit(escrow: options.escrow)
                for file in files {

                    let handle = try conduit.fileOpen(filename: file, fileMode: .rdOnly)
                    let data = try conduit.fileRead(handle: handle)
                    try conduit.fileClose(handle: handle)

                    print(String(data: data, encoding: .utf8) ?? "")
                }
                break // only connect to the first device
            }

            //try options.show(results)
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
        case .array:
            return "array"
        case .dict:
            return "dictionary"
        case .date:
            return plist.date?.description
        case .data:
            return plist.data?.description
        case .key:
            return plist.key
        case .uid:
            return plist.uid?.description
        case .none:
            return "none"
        }
    }
}
