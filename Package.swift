// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DesktopPet",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DesktopPet", targets: ["DesktopPet"])
    ],
    targets: [
        .executableTarget(
            name: "DesktopPet",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "DesktopPetTests",
            dependencies: ["DesktopPet"]
        )
    ]
)
