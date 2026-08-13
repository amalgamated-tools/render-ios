// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RenderAPI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "RenderAPI", targets: ["RenderAPI"]),
        // Test-only helpers, shipped as a product because the app target's tests live outside this
        // package and can't reach another target's test sources.
        //
        // Known wart this creates: the app binary and the test bundle each statically link their
        // own copy of RenderAPI, so under the app test runner a dynamic cast on a package type
        // (`error as? RenderError`) fails when the value was created on the other side. App tests
        // therefore assert on user-visible outcomes (phase, message presence) rather than on
        // specific RenderError cases. Making the products `.dynamic` doesn't fix it: Xcode refuses
        // a dynamic product that shares its target's name, and the TestSupport→RenderAPI target
        // dependency would still embed a second static copy.
        .library(name: "RenderAPITestSupport", targets: ["RenderAPITestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
        // Already in the graph under swift-openapi-runtime, but declared explicitly because both
        // targets `import HTTPTypes` directly — leaning on the transitive copy leaves the symbols
        // out when Xcode builds these products as dynamic frameworks.
        .package(url: "https://github.com/apple/swift-http-types", from: "1.6.0"),
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
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ]
        ),
        .target(
            name: "RenderAPITestSupport",
            dependencies: [
                "RenderAPI",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ]
        ),
        .testTarget(
            name: "RenderAPITests",
            dependencies: ["RenderAPI", "RenderAPITestSupport"]
        ),
    ]
)
