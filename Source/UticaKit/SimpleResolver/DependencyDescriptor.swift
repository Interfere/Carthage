/// Descriptor of one particular dependency.
///
/// This is just another representation of an element in
/// the list of resolved dependencies, that convenient
/// for internal use during the iteration of resolution algorithm
internal struct DependencyDescriptor: Hashable {
  internal let dependency: Dependency
  internal let version: PinnedVersion
}

extension DependencyDescriptor: Comparable {
  internal static func < (_ lhs: DependencyDescriptor, _ rhs: DependencyDescriptor) -> Bool {
    let leftSemantic = SemanticVersion.from(lhs.version).value ?? SemanticVersion(0, 0, 0)
    let rightSemantic = SemanticVersion.from(rhs.version).value ?? SemanticVersion(0, 0, 0)

    // Try higher versions first.
    return leftSemantic > rightSemantic
  }

  internal static func == (_ lhs: DependencyDescriptor, _ rhs: DependencyDescriptor) -> Bool {
    guard lhs.dependency == rhs.dependency else { return false }

    let leftSemantic = SemanticVersion.from(lhs.version).value ?? SemanticVersion(0, 0, 0)
    let rightSemantic = SemanticVersion.from(rhs.version).value ?? SemanticVersion(0, 0, 0)
    return leftSemantic == rightSemantic
  }
}
