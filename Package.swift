// swift-tools-version:5.0
import PackageDescription

let package = Package(
  name: "Utica",
  products: [
    .library(name: "XCDBLD", targets: ["XCDBLD"]),
    .library(name: "UticaKit", targets: ["UticaKit"]),
    .executable(name: "utica", targets: ["utica"])
  ],
  dependencies: [
    .package(url: "https://github.com/antitypical/Result.git", from: "5.0.0"),
    .package(url: "https://github.com/Interfere/ReactiveTask.git", from: "0.16.1"),
    .package(url: "https://github.com/Carthage/Commandant.git", from: "0.18.0"),
    .package(url: "https://github.com/jdhealy/PrettyColors.git", from: "5.0.2"),
    .package(url: "https://github.com/ReactiveCocoa/ReactiveSwift.git", from: "6.5.0"),
    .package(url: "https://github.com/mdiep/Tentacle.git", from: "0.14.0"),
    .package(url: "https://github.com/thoughtbot/Curry.git", from: "5.0.0"),
    .package(url: "https://github.com/Quick/Quick.git", from: "4.0.0"),
    .package(url: "https://github.com/Quick/Nimble.git", from: "9.2.0")
  ],
  targets: [
    .target(
      name: "XCDBLD",
      dependencies: ["Result", "ReactiveSwift", "ReactiveTask"]
    ),
    .testTarget(
      name: "XCDBLDTests",
      dependencies: ["XCDBLD", "Quick", "Nimble"]
    ),
    .target(
      name: "UticaKit",
      dependencies: ["XCDBLD", "Tentacle", "Curry"]
    ),
    .testTarget(
      name: "UticaKitTests",
      dependencies: ["UticaKit", "Quick", "Nimble"],
      exclude: ["Resources/FakeOldObjc.framework"]
    ),
    .target(
      name: "utica",
      dependencies: ["XCDBLD", "UticaKit", "Commandant", "Curry", "PrettyColors"],
      exclude: ["swift-is-crashy.c"]
    )
  ],
  swiftLanguageVersions: [.v5]
)
