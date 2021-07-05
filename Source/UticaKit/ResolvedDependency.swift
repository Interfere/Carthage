/// Descriptor of one particular dependency.
///
/// This is just another representation of an element in
/// the list of resolved dependencies, that convenient
/// for internal use during the iteration of resolution algorithm
public struct ResolvedDependency: Hashable {
  public let dependency: Dependency
  public let version: PinnedVersion
}

extension ResolvedDependency: Comparable {
  public static func < (_ lhs: ResolvedDependency, _ rhs: ResolvedDependency) -> Bool {
    let leftSemantic = SemanticVersion.from(lhs.version).value ?? SemanticVersion(0, 0, 0)
    let rightSemantic = SemanticVersion.from(rhs.version).value ?? SemanticVersion(0, 0, 0)

    // Try higher versions first.
    return leftSemantic > rightSemantic
  }

  public static func == (_ lhs: ResolvedDependency, _ rhs: ResolvedDependency) -> Bool {
    guard lhs.dependency == rhs.dependency else { return false }

    let leftSemantic = SemanticVersion.from(lhs.version).value ?? SemanticVersion(0, 0, 0)
    let rightSemantic = SemanticVersion.from(rhs.version).value ?? SemanticVersion(0, 0, 0)
    return leftSemantic == rightSemantic
  }
}
