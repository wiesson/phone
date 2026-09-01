// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Phone",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Phone", targets: ["Phone"]),
        .executable(name: "phone-mcp", targets: ["phone-mcp"])
    ],
    targets: [
        .target(name: "PhoneAutomation"),
        .executableTarget(
            name: "Phone",
            dependencies: ["PhoneAutomation"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("Contacts"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "phone-mcp",
            dependencies: ["PhoneAutomation"],
            path: "Sources/PhoneMCP",
            exclude: ["Info.plist"],
            linkerSettings: [
                // The sandbox needs an identity for a tool without a bundle.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PhoneMCP/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "PhoneTests",
            dependencies: ["Phone", "PhoneAutomation"],
            resources: [.process("Fixtures")]
        )
    ]
)
