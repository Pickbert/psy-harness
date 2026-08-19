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
    dependencies: [
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", exact: "0.14.2")
    ],
    targets: [
        .executableTarget(
            name: "DesktopPet",
            dependencies: [
                .product(name: "CoreXLSX", package: "CoreXLSX")
            ],
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
