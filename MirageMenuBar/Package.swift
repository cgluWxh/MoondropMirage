// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MirageMenuBar",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "MirageMenuBar", targets: ["MirageMenuBar"]),
    ],
    targets: [
        .executableTarget(
            name: "MirageMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
