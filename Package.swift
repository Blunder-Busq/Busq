// swift-tools-version:5.5
import PackageDescription

extension Platform {
    /// Every platform except windows
    static let nonwindows: [Platform] = [
        .android,
        .linux,
        .macOS,
        .iOS,
        .tvOS,
        .watchOS,
        .macCatalyst,
    ]
}

#if os(Windows)
let pathsep = "\\"
#else
let pathsep = "/"
#endif

var package = Package(
    name: "Busq",
    platforms: [ .macOS(.v11), .iOS(.v14) ],
    products: [
        .library(name: "Busq", targets: ["Busq"]),
        .executable(name: "busq", targets: ["BusqTool"]),
    ],
    dependencies: [
        .package(name: "swift-argument-parser", url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "Busq",
            dependencies: [
                "libimobiledevice",
            ],
            path: "Sources/Busq",
            exclude: [
            ]
        ),
        .target(
            name: "libplist",
            dependencies: [],
            path: "Sources/libplist",
            exclude: [
                "NEWS",
                "COPYING",
                "README.md",
                "AUTHORS",
                "Makefile.am",
                "autogen.sh",
                "ltmain.sh",
                "doxygen.cfg.in",
                "COPYING.LESSER",
                "git-version-gen",
                "cython",
                "docs",
                "fuzz",
                "tools",
                "m4",
                "configure.ac",
                "libcnary/Makefile.am",
                "libcnary/COPYING",
                "include/Makefile.am",
                "libcnary/README",
                "libcnary/cnary.c",
                "src/Makefile.am",
                "src/libplist-2.0.pc.in",
                "src/libplist++-2.0.pc.in",
                "src/String.cpp",
                "src/Node.cpp",
                "src/Key.cpp",
                "src/Dictionary.cpp",
                "src/Data.cpp",
                "src/Array.cpp",
                "src/Date.cpp",
                "src/Uid.cpp",
                "src/Structure.cpp",
                "src/Integer.cpp",
                "src/Boolean.cpp",
                "src/Real.cpp",
            ],
            sources: [
                "src/time64.c",
                "src/xplist.c",
                "src/hashtable.c",
                "src/base64.c",
                "src/plist.c",
                "src/ptrarray.c",
                "src/bytearray.c",
                "src/jplist.c",
                "src/jsmn.c",
                "src/bplist.c",
                "libcnary/node.c",
                "libcnary/node_list.c",
            ],
            cSettings: [
                .define("WIN32", .when(platforms: [.windows])),
                .define("HAVE_STRNDUP", .when(platforms: Platform.nonwindows)),
                .define("HAVE_VASPRINTF", .when(platforms: Platform.nonwindows)),
                .define("HAVE_ASPRINTF", .when(platforms: Platform.nonwindows)),
                .headerSearchPath("src"),
                .headerSearchPath("libcnary\(pathsep)include"),
            ]
        ),
        .target(
            name: "mbedtls",
            dependencies: [],
            path: "Sources/mbedtls",
            exclude: [
                "3rdparty",
                "visualc",
                "docs",
                "LICENSE",
                "BUGS.md",
                "ChangeLog.d",
                "CONTRIBUTING.md",
                "SECURITY.md",
                "SUPPORT.md",
                "BRANCHES.md",
                "dco.txt",
                "cmake",
                "programs",
                "scripts",
                "include/CMakeLists.txt",
                "DartConfiguration.tcl",
                "doxygen",
                "library/Makefile",
                "Makefile",
                "README.md",
                "ChangeLog",
                "CMakeLists.txt",
                "configs/README.txt",
                "library/CMakeLists.txt",
            ]
        ),
        .target(
            name: "libimobiledevice-glue",
            dependencies: ["libplist"],
            path: "Sources/libimobiledevice-glue",
            exclude: [
                "COPYING",
                "README.md",
                "autogen.sh",
                "configure.ac",
                "m4",
                "Makefile.am",
                "src/Makefile.am",
                "include/Makefile.am",
                "src/libimobiledevice-glue-1.0.pc.in",
            ],
            cSettings: [
                .define("WIN32", .when(platforms: [.windows])),
                .define("HAVE_GETIFADDRS", .when(platforms: Platform.nonwindows)),
                .define("HAVE_STRNDUP", .when(platforms: Platform.nonwindows)),
                .define("HAVE_STPNCPY", .when(platforms: Platform.nonwindows)),
                .define("HAVE_VASPRINTF", .when(platforms: Platform.nonwindows)),
                .define("HAVE_ASPRINTF", .when(platforms: Platform.nonwindows)),
                .define("MBEDTLS_PSA_ACCEL_ECC_BRAINPOOL_P_R1_256"),
            ]
        ),
        .target(
            name: "libusbmuxd",
            dependencies: [
                "libplist",
                "libimobiledevice-glue",
            ],
            path: "Sources/libusbmuxd",
            exclude: [
                "NEWS",
                "AUTHORS",
                "COPYING",
                "README.md",
                "autogen.sh",
                "configure.ac",
                "m4",
                "docs",
                "tools",
                "git-version-gen",
                "Makefile.am",
                "src/Makefile.am",
                "src/libusbmuxd-2.0.pc.in",
                "include/Makefile.am",
            ],
            cSettings: [
                .define("WIN32", .when(platforms: [.windows])),
                .define("HAVE_STRNDUP", .when(platforms: Platform.nonwindows)),
                .define("HAVE_STPNCPY", .when(platforms: Platform.nonwindows)),
                .define("HAVE_VASPRINTF", .when(platforms: Platform.nonwindows)),
                .define("HAVE_ASPRINTF", .when(platforms: Platform.nonwindows)),
                .define("PACKAGE_STRING", to: "\"libusbmuxd 2.0.2\""),
            ]
        ),
        .target(
            name: "libimobiledevice",
            dependencies: [
                "libusbmuxd",
                "mbedtls",
            ],
            path: "Sources/libimobiledevice",
            exclude: [
                "NEWS",
                "COPYING",
                "README.md",
                "AUTHORS",
                "Makefile.am",
                "autogen.sh",
                "configure.ac",
                "docs",
                "cython",
                "m4",
                "src/libimobiledevice-1.0.pc.in",
                "COPYING.LESSER",
                "doxygen.cfg.in",
                "git-version-gen",
                "tools",
                "3rd_party",
                "Makefile.am",
                "src/Makefile.am",
                "include/Makefile.am",
                "common/Makefile.am",
            ],
            sources: [
                "src",
                "common",
                // HAVE_WIRELESS_PAIRING support
                "3rd_party/ed25519",
                "3rd_party/libsrp6a-sha512",
            ],
            cSettings: [
                .define("WIN32", .when(platforms: [.windows])),
                // .define("HAVE_WIRELESS_PAIRING"),
                .define("HAVE_MBEDTLS"),
                .define("HAVE_STRNDUP", .when(platforms: Platform.nonwindows)),
                .define("HAVE_VASPRINTF", .when(platforms: Platform.nonwindows)),
                .define("HAVE_ASPRINTF", .when(platforms: Platform.nonwindows)),
                .headerSearchPath("src"),
                .headerSearchPath("include\(pathsep)libimobiledevice"),
            ]
        ),
        .testTarget(name: "BusqTests", dependencies: [
            "Busq",
        ]),
        .executableTarget(name: "BusqTool", dependencies: [
            "Busq",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ])
    ]
)

// when testing on iOS simulator, the presence of the BusqTool target causes a failure with:
// ???xcodebuild: error: Scheme Busq is not currently configured for the test action.???
// so we pre-process by making this true and removing the target
let excludeCLI = false

if excludeCLI {
    package.targets = package.targets.filter({
        $0.type != .executable
    })
    package.products = package.products.filter({
        $0.name != "busq"
    })
}
