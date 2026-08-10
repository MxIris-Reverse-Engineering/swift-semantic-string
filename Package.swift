// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = Context.environment[key]
    guard let value else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
}

let usingLocalDependencies = envEnable("USING_LOCAL_DEPENDENCIES")

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool = usingLocalDependencies, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath
        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled, let traits):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: #filePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path, traits: traits)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "swift-semantic-string",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .macCatalyst(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Semantic",
            targets: ["Semantic"],
        ),
        // The shared `Transformer` namespace and `Module` protocol. Concrete
        // transformers ship with the library that owns their vocabulary, and
        // all extend this one namespace so a consumer importing several of
        // them still writes `Transformer.<Module>` unqualified.
        .library(
            name: "OutputTransformer",
            targets: ["OutputTransformer"],
        ),
    ],
    targets: [
        .target(
            name: "Semantic",
        ),
        // Holds only the `Transformer` namespace and the `Module` protocol.
        // Concrete transformers live with their subject matter, so this target
        // has no dependency of its own — not even on `Semantic`.
        .target(
            name: "OutputTransformer",
        ),
        .testTarget(
            name: "SemanticTests",
            dependencies: ["Semantic"],
        ),
        .testTarget(
            name: "OutputTransformerTests",
            dependencies: ["OutputTransformer"],
        ),
    ],
)
