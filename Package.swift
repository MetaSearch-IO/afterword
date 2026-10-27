// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Afterword",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AfterwordCore", targets: ["AfterwordCore"]),
        .executable(name: "Afterword", targets: ["AfterwordApp"]),
        .executable(name: "afterwordctl", targets: ["AfterwordCLI"])
    ],
    targets: [
        .target(name: "AfterwordCore"),
        .executableTarget(name: "AfterwordApp", dependencies: ["AfterwordCore"]),
        .executableTarget(name: "AfterwordCLI", dependencies: ["AfterwordCore"]),
        .testTarget(name: "AfterwordCoreTests", dependencies: ["AfterwordCore"]),
        .testTarget(name: "AfterwordAppTests", dependencies: ["AfterwordApp"])
    ]
)
