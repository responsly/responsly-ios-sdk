// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ResponslySDK",
    platforms: [
        .iOS(.v15),
        // macOS is listed only so `swift test` can run the platform-independent logic.
        .macOS(.v12),
    ],
    products: [
        .library(name: "ResponslySDK", targets: ["ResponslySDK"]),
    ],
    targets: [
        .target(
            name: "ResponslySDK",
            path: "Sources/ResponslySDK",
            resources: [
                .process("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "ResponslySDKTests",
            dependencies: ["ResponslySDK"],
            path: "Tests/ResponslySDKTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
