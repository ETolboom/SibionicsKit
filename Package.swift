// swift-tools-version:5.9
//
// Package.swift
// SibionicsKit
//
// The kit itself is built as an Xcode project inside the Trio workspace (it
// needs `LoopKit`/`LoopKitUI`, which come from the workspace build products).
// This manifest exists so the protocol, crypto and BLE layers — everything that
// does not import LoopKit — can be built and tested on their own, with no
// workspace and no hardware:
//
//     swift test
//
// `SibionicsKit/Services` is the only LoopKit-dependent directory and is
// excluded here.
//

import PackageDescription

let package = Package(
    name: "SibionicsKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SibionicsKit", targets: ["SibionicsKit"])
    ],
    targets: [
        .target(
            name: "SibionicsKit",
            path: "SibionicsKit",
            exclude: ["Services"]
        ),
        .executableTarget(
            name: "sibionics-decode",
            dependencies: ["SibionicsKit"],
            path: "Sources/SibionicsDecode"
        ),
        .testTarget(
            name: "SibionicsKitTests",
            dependencies: ["SibionicsKit"],
            path: "SibionicsKitTests",
            // Read through `#filePath` rather than the bundle, so the fixture is
            // not a target resource.
            exclude: ["Fixtures"]
        )
    ]
)
