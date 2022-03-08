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
