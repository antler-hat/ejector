// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Ejector",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Ejector", targets: ["Ejector"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Ejector",
            dependencies: [],
            path: "Ejector",
            exclude: ["Info.plist"],
            sources: ["Sources"],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(name: "EjectorTests", dependencies: ["Ejector"])
    ]
)
