import ReactiveSwift
import Result

/// State of resolution cycle.
///
/// At each step of resolution algorithm it contains
/// a set of candidates to resolve, requirements map,
/// list of resolved dependencies and an additional filter
/// routine.
internal struct SimpleResolverState {
  /// Set of candidates to be resolved at next iteration of resolution algorithm
  internal let candidates: Set<ResolvedDependency>
  /// Map of requirements, gathered up to the current resolution iteration
  internal let requirements: DependencyRequirements
  /// List of resolved dependencies
  internal let resolved: [Dependency: PinnedVersion]
  /// Filter routine used for algorithm tuning and adjustment
  internal let filter: (ResolvedDependency, VersionSpecifier) -> Bool
}

extension SimpleResolverState {
  /// Process candidates
  ///
  /// The routine is the seconds step of dependency resolution algorithm.
  /// It fetches dependencies for `candidates`, selected at first step,
  /// and updates `requirements`
  ///
  /// - Parameter dependenciesForDependency: depdendencies fetcher
  /// - Parameter resolvedGitReference: git reference resolver
  ///
  /// - Returns: `SignalProducer` that emits either a new state with new
  ///            `requirements` or `CarthageError`
  func processCandidates(
    with dependenciesForDependency: @escaping (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  ) -> SignalProducer<SimpleResolverState, CarthageError> {
    Helper.collectDependencies(
      for: candidates,
      dependenciesForDependency: dependenciesForDependency,
      resolvedGitReference: resolvedGitReference
    )
    .attemptMap { dependencyMap in
      Result(catching: { try Helper.updated(requirements: requirements, dependencyMap: dependencyMap) })
    }
    .map {
      SimpleResolverState(
        candidates: candidates,
        requirements: $0,
        resolved: resolved,
        filter: filter
      )
    }
  }

  /// Update resolved dependencies.
  ///
  /// The routine is the third step of dependency resolution algorithm.
  /// It updates the list of `resolved` dependencies using `requirements`
  /// updated on previous step.
  ///
  /// - Returns: `SignalProducer` that emits either a new state with new list of
  ///            `resolved` dependencies or `CarthageError`
  func updateResolved() -> SignalProducer<SimpleResolverState, CarthageError> {
    SignalProducer(value: self)
      .map { state in
        let allDependencies = state.resolved.map { ResolvedDependency(dependency: $0, version: $1) } + candidates
        let resolved = allDependencies
          .filter { state.requirements.versionSpecifier(for: $0.dependency).isSatisfied(by: $0.version) }
          .reduce(into: [:]) { result, descriptor in result[descriptor.dependency] = descriptor.version }
        return SimpleResolverState(
          candidates: [],
          requirements: state.requirements,
          resolved: resolved,
          filter: state.filter
        )
      }
  }

  /// Select candidates to process
  ///
  /// This routine is the first step of dependency resolution algorithm. It selects
  /// `candidates` based on `requirements` and the list of `resolved`
  /// dependencies.
  ///
  /// - Parameter versionsForDependency: versions fetcher
  /// - Parameter resolvedGitReference: git reference resolver
  ///
  /// - Returns: `SignalProducer` that emits either a new state with `candidates`
  ///            or `CarthageError`
  func selectCandidates(
    versionsForDependency: @escaping (Dependency) -> SignalProducer<PinnedVersion, CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  ) -> SignalProducer<SimpleResolverState, CarthageError> {
    SignalProducer(value: self)
      .flatMap(.concat) { state in
        Helper.selectCandidates(
          for: state.requirements.dependencies.subtracting(state.resolved.keys),
          requirements: state.requirements,
          versionsForDependency: versionsForDependency,
          resolvedGitReference: resolvedGitReference,
          filter: { state.filter($0, state.requirements.versionSpecifier(for: $0.dependency)) }
        )
        .map {
          SimpleResolverState(
            candidates: $0,
            requirements: state.requirements,
            resolved: state.resolved,
            filter: state.filter
          )
        }
      }
  }
}

/// Collection of private helper routines used for dependency resolution
private enum Helper {
  /// Helper routine that updates requirements based onb dependency map
  ///
  /// - Parameter requirement: existing requirements
  /// - Parameter dependencyMap: map `[Dependency -> Requirements]`
  ///
  /// - Returns: `requirements` updated with `dependencyMap`
  /// - Throws: `CarthageError`
  static func updated(
    requirements: DependencyRequirements,
    dependencyMap: [Dependency: [(Dependency, VersionSpecifier)]]
  ) throws -> DependencyRequirements {
    var newRequirements = requirements
    for (dependency, requirements) in dependencyMap {
      try newRequirements.merge(with: requirements, requiredBy: dependency)
    }
    return newRequirements
  }

  /// Helper routine that collects dependencies for a set of candidates.
  ///
  /// The routine is used to fetch dependencies for previousely selected candidates.
  /// - Parameter candidates: a set of candidates
  /// - Parameter dependenciesForDependency: depdendencies fetcher
  /// - Parameter resolvedGitReference: git reference resolver
  ///
  /// - Returns: `SignalProducer` that emits either a map `[Candidate -> [Dependency]]`
  ///            or `CarthageError`
  static func collectDependencies(
    for candidates: Set<ResolvedDependency>,
    dependenciesForDependency: @escaping (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  ) -> SignalProducer<[Dependency: [(Dependency, VersionSpecifier)]], CarthageError> {
    SignalProducer(candidates)
      .flatMap(.merge) { descriptor in
        dependenciesForDependency(descriptor.dependency, descriptor.version)
          .flatMap(.concat) { dependency, specifier -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> in
            if case let .gitReference(ref) = specifier {
              return resolvedGitReference(dependency, ref)
                .map { (dependency, VersionSpecifier.gitReference($0.commitish)) }
            }
            return SignalProducer(value: (dependency, specifier))
          }
          .map { (descriptor, $0, $1) }
      }
      .collect()
      .map { collection in
        var dependencyMap = [Dependency: [(Dependency, VersionSpecifier)]]()
        for (descriptor, dependency, specifier) in collection {
          dependencyMap[descriptor.dependency, default: []].append((dependency, specifier))
        }
        return dependencyMap
      }
  }

  /// Helper routine that selects a set of candidates for next resolution cycle iteration.
  ///
  /// - Parameter dependencies: set of yet unresolved dependencies
  /// - Parameter requirements: current requirements for resolution algorithm
  /// - Parameter versionsForDependency: versions fetcher
  /// - Parameter resolvedGitReference: git reference resolver
  /// - Parameter filter: routine to filter out candidates, that do not satisfy some external requirements
  ///
  /// - Returns: `SignalProducer` that emits either set of candidates for next iteration of the
  ///            resolution algorithm, or `CarthageError`
  static func selectCandidates(
    for dependencies: Set<Dependency>,
    requirements: DependencyRequirements,
    versionsForDependency: @escaping (Dependency) -> SignalProducer<PinnedVersion, CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>,
    filter: @escaping (ResolvedDependency) -> Bool
  ) -> SignalProducer<Set<ResolvedDependency>, CarthageError> {
    SignalProducer(dependencies)
      .flatMap(.merge) { dependency -> SignalProducer<ResolvedDependency?, CarthageError> in
        collectAvailableVersions(
          for: dependency,
          requirements: requirements,
          versionsForDependency: versionsForDependency,
          resolvedGitReference: resolvedGitReference
        )
        .flatMap(.merge) {
          selectCandidate(for: dependency, availableVersions: $0, filter: filter)
        }
      }
      .compactMap { $0 }
      .collect()
      .map(Set.init)
  }

  /// Private helper routine that fetches all available version for `dependency`
  /// that satisfy current `requirements`.
  ///
  /// - Parameter dependency: candidate to fetch available versions
  /// - Parameter requirements: current requirements for resolution algorithm
  /// - Parameter versionsForDependency: versions fetcher
  /// - Parameter resolvedGitReference: git reference resolver
  ///
  /// - Returns: `SignalProducer` that eits either list of available version for `dependency`
  ///            or `CarthageError`
  private static func collectAvailableVersions(
    for dependency: Dependency,
    requirements: DependencyRequirements,
    versionsForDependency: (Dependency) -> SignalProducer<PinnedVersion, CarthageError>,
    resolvedGitReference: (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  ) -> SignalProducer<[PinnedVersion], CarthageError> {
    let versionProducer: SignalProducer<PinnedVersion, CarthageError>
    switch requirements.versionSpecifier(for: dependency) {
      case let .gitReference(ref):
        versionProducer = resolvedGitReference(dependency, ref)
      default:
        versionProducer = versionsForDependency(dependency)
    }

    return versionProducer
      .filter { requirements.isSatisfied(by: $0, for: dependency) }
      .collect()
      .attempt {
        $0.isEmpty ?
          .failure(CarthageError.requiredVersionNotFound(dependency, requirements.versionSpecifier(for: dependency)))
          : .success(())
      }
  }

  /// Private helper routine used as a step during resolution algorithm.
  /// Selects the most recent available version for `dependency` that satisfies
  /// `filter` routine.
  ///
  /// - Parameter dependency: The dependency
  /// - Parameter availableVersions: list of all available versions for `dependency`
  /// - Parameter filter: routine to filter `availableVersions`
  ///
  /// - Returns: SignalProducer that emits either descriptor for next candidate of `dependency` or `nil`
  ///            if all available versions were filtered out.
  private static func selectCandidate(
    for dependency: Dependency,
    availableVersions: [PinnedVersion],
    filter: @escaping (ResolvedDependency) -> Bool
  ) -> SignalProducer<ResolvedDependency?, Never> {
    SignalProducer(availableVersions)
      .map { ResolvedDependency(dependency: dependency, version: $0) }
      .filter(filter)
      .collect()
      .map { $0.sorted().first }
  }
}
