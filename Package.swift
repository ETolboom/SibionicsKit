// swift-tools-version:5.9
//
// Package.swift
// SibionicsKit
//
// The kit itself is built as an Xcode project inside the Trio workspace (it
// needs `LoopKit`/`LoopKitUI`, which come from the workspace build products).
// This manifest exists so the host runtime, BLE layer and the Rust driver's
// bindings — everything that does not import LoopKit — can be built and tested
// on their own, with no workspace and no hardware (run Scripts/build-rust.sh
// first):
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
        // The cgm-sibionics Rust driver, built by `Scripts/build-rust.sh`.
        .binaryTarget(
            name: "cgm_sibionics_ffiFFI",
            path: "Rust/CgmSibionicsFFI.xcframework"
        ),
        .target(
            name: "SibionicsKit",
            dependencies: ["cgm_sibionics_ffiFFI"],
            path: "SibionicsKit",
            exclude: ["Services"]
        ),
        .testTarget(
            name: "SibionicsKitTests",
            dependencies: ["SibionicsKit"],
            path: "SibionicsKitTests"
        )
    ]
)
