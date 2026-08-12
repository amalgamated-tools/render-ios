// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RenderAPI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RenderAPI", targets: ["RenderAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.1"),
        // Build-time only: `swift run swift-openapi-generator`, invoked by
        // Scripts/generate-api.sh. Generated output is committed, so this is never needed to
        // *build* the package — only to regenerate it.
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.0"),
    ],
    targets: [
        .target(
            name: "RenderAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        ),
        .testTarget(
            name: "RenderAPITests",
            dependencies: ["RenderAPI"]
        ),
    ]
)
