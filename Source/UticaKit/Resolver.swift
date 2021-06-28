import Foundation
import ReactiveSwift
import Result

/// Protocol for resolving acyclic dependency graphs.
public protocol Resolver {
  init(
    versionsForDependency: @escaping (Dependency) -> SignalProducer<PinnedVersion, CarthageError>,
    dependenciesForDependency: @escaping (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  )

  func resolve(
    dependencies: [Dependency: VersionSpecifier],
    lastResolved: [Dependency: PinnedVersion],
    dependenciesToUpdate: [String]
  ) -> SignalProducer<[Dependency: PinnedVersion], CarthageError>
}
