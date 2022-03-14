# Busq

Busq (pronounced: "busk") is a swift module for managing iOS devices.
It provides a convenient API for accessing iOS devices via USB or the Network,
and provides the ability to:

 - Access device screenshots
 - Add, remove, and manage apps


## Building

Busq bundles all the dependencies it needs, and compiles on macOS, Linux, and Windows.

Check it out and build using the following commands:

```
git clone https://github.com/Blunder-Busq/Busq.git
cd Busq
swift test
```

### Command Line Tool

The Busq library also includes a command-line interface (CLI).
The tool is currently only tested on macOS.
For Windows and Linux, please file an [issue](https://github.com/Blunder-Busq/Busq/issues) if there are problems.

```
% swift run busq

OVERVIEW: A utility for interfacing with iOS devices.

USAGE: busq <subcommand>

OPTIONS:
  -h, --help              Show help information.

SUBCOMMANDS:
  list                    List available devices.
  ls                      List directory contents.
  cat                     Concatenate and print files.
  rm                      Remove directory entries.
  rmdir                   Remove folder and contents.
  mkdir                   Make directories.
  transmit                Copy file(s) to device.
  receive                 Copy file(s) from device.
  install                 Install app(s) from remote ipa.
  uninstall               Uninstalls app(s) from device.
  apps                    List installed apps.

  See 'busq help <subcommand>' for detailed help.
```

Devices can be listed with the `list` command:

```
% swift run busq list

Device list:
UniqueDeviceID: 00098030-00122956FA63832E
   BuildVersion: 19D52
   ChipID: 32816
   DeviceClass: iPhone
   DeviceName: Bob's iPhone
   FirmwareVersion: iBoot-7429.82.1
   HardwarePlatform: t8030
   PasswordProtected: true
   ProductName: iPhone OS
   ProductType: iPhone12,8
   ProductVersion: 15.3.1
```

For other commands,
the tool will connect to the first available device 
(preferring wired USB connections over WiFi).
A specific device can be selected using the `--udids` flag.


```
% swift run busq apps --udids 00098030-00122956FA63832E
[0/0] Build complete!
com.netflix.Netflix
com.mojang.minecraftpe
com.apple.TVRemote
```


IPA files that are already signed with a developer account 
can be side-loaded using the `install` command:

```
% swift run busq install --progress Cloud-Cuckoo-iOS.signed.ipa

[🁢🁢🁢🁢🁢🁢🁢🁢🁢🁢🁢🁢🁢🁢🁢🁢------------------------]  41% Cloud-Cuckoo-iOS.signed.ipa
```

Individual files on the device can also be explicitly managed using the
`ls`, `mkdir`, `transmit`, and `receive` commands.
See the `--help` output for each of these commands for more details.

### SPM

Busq is distributed exclusively as a [Swift Package Manager](https://swift.org/package-manager/) libray. To use it in your project, add it to your project like so:

```swift
// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "MyLibrary",
    products: [ .library(name: "MyLibrary", targets: ["MyLibrary"]) ],
    dependencies: [
        .package(name: "Busq", url: "https://github.com/Blunder-Busq/Busq.git", .branch("main")),
    ],
    targets: [
        .target(name: "MyLibrary", dependencies: [
            .product(name: "Busq", package: "Busq"),
        ]
    ]
)
```

## License

This software is licensed under the
GNU Affero General Public License 3.0,
and embeds the following external projects:

 - [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) (GPL-3.0 License)
 - [usbmuxd](https://github.com/libimobiledevice/usbmuxd) (GPL-3.0 License)
 - [libplist](https://github.com/libimobiledevice/libplist) (LGPL-2.1 License)
 - [mbedtls](https://github.com/ARMmbed/mbedtls) (Apache 2.0 License)

In addition, some of the Swift APIs are based on the work from the following project:

 - [SymbolicatorX](https://github.com/Yueoaix/SymbolicatorX) (MIT License)
