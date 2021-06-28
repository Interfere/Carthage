/// Struct that represents a single requirement.
///
/// Used as a single entry in `DependencyRequirements`
internal struct DependencyRequirement {
  /// Describes which versions are acceptable for satisfying a dependency requirement
  internal let specifier: VersionSpecifier
  /// Describes the dependency that defines the requirements. `nil` if requirement is from the root `Cartfile`
  internal let constraintor: Dependency?
}

/// Collection of all requirements.
internal struct DependencyRequirements {
  private var storage: [Dependency: DependencyRequirement]

  private init(storage: [Dependency: DependencyRequirement]) {
    self.storage = storage
  }

  init(dependencies: [Dependency: VersionSpecifier]) {
    self.storage = dependencies.mapValues { DependencyRequirement(specifier: $0, constraintor: nil) }
  }

  var dependencies: Set<Dependency> {
    Set(storage.keys)
  }

  func versionSpecifier(for dependency: Dependency) -> VersionSpecifier {
    storage[dependency]?.specifier ?? .any
  }

  func isSatisfied(by version: PinnedVersion, for dependency: Dependency) -> Bool {
    return versionSpecifier(for: dependency).isSatisfied(by: version)
  }

  func isSatisfied(by dependency: DependencyDescriptor) -> Bool {
    isSatisfied(by: dependency.version, for: dependency.dependency)
  }

  mutating func merge(with requirements: [(Dependency, VersionSpecifier)], requiredBy dependency: Dependency?) throws {
    try requirements.forEach {
      try merge(with: $0, requiredBy: dependency)
    }
  }

  mutating func merge(with requirement: (Dependency, VersionSpecifier), requiredBy dependency: Dependency?) throws {
    guard let oldRequirement = storage[requirement.0] else {
      storage[requirement.0] = DependencyRequirement(specifier: requirement.1, constraintor: dependency)
      return
    }

    guard let newSpecifier = intersection(oldRequirement.specifier, requirement.1) else {
      let existingReqs: CarthageError.VersionRequirement = (specifier: oldRequirement.specifier, fromDependency: oldRequirement.constraintor)
      let newReqs: CarthageError.VersionRequirement = (specifier: requirement.1, fromDependency: dependency)
      throw CarthageError.incompatibleRequirements(requirement.0, existingReqs, newReqs)
    }

    let constraintor = requirement.1.isStricter(than: oldRequirement.specifier) ? dependency : oldRequirement.constraintor
    storage[requirement.0] = DependencyRequirement(specifier: newSpecifier, constraintor: constraintor)
  }
}
