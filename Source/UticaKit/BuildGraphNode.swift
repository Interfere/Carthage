/// Internal struct used to determine the order to build dependencies.
///
internal struct BuildGraphNode: Hashable {
  internal let resolvedDependency: ResolvedDependency
  internal let dependencies: Set<Dependency>
}

extension BuildGraphNode {
  internal var dependency: Dependency {
    resolvedDependency.dependency
  }

  internal var version: PinnedVersion {
    resolvedDependency.version
  }
}
