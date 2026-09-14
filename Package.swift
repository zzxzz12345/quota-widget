// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuotaWidget",
            path: "Sources/QuotaWidget"
        ),
        .testTarget(
            name: "QuotaWidgetTests",
            dependencies: ["QuotaWidget"],
            path: "Tests/QuotaWidgetTests"
        )
    ]
)
