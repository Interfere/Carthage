import Foundation
import Result
import ReactiveSwift
import Commandant

/// Responsible for resolving acyclic dependency graphs.
///
/// `SimpleResolver` uses a recursive algorithm to resolve all requested dependencies
/// to the most recent versions satisfied by `requirements` stated in `Cartfile`.
/// Algorithm contains three steps:
///  * __Step 1 — Candidates selection:__
///    At this step algorithm selects a list of `candidates` for resolution, using `requirements`
///    and a list of already `resolved` dependencies. For each unresolved dependency, mentioned in
///    `requirements` it fetches a list of all available versions (or resolves git reference, that may be either
///    a commit hash or branch name) and selects the most recent one, which satisfies the `requirements`.
///  * __Step 2 — Expansion:__
///    At this step algorithm fetches `Cartfile` for each `candidate` and updates `requirements`
///    with respect to the new tuples `(Dependency, VersionSpecifier)` for each dependency.
///    `CarthageError.incompatibleRequirements` is emitted at this step due to inability
///    to find intersection of existing and new requirements.
///  * __Step 3 — Resolution:__
///    At this step algorithm determines a list of `resolved`, filtering all fetched dependencies
///    with the respect to the `requirements` updated at the previous step. If any of already
///    `resolved` dependencies does not meet new `requirements`, it might be filtere out during this
///    step.
///
/// After the third step algorithm calls itself recursively. Termination condition is checked after the __Step 1__:
/// if the list of `candidates` is empty, a list of `resolved` dependencies is returned to the caller.
///
public struct SimpleResolver: ResolverProtocol {
	private let versionsForDependency: (Dependency) -> SignalProducer<PinnedVersion, CarthageError>
	private let resolvedGitReference: (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
	private let dependenciesForDependency: (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>

	/// Instantiates a dependency graph resolver with the given behaviors.
	///
	/// versionsForDependency - Sends a stream of available versions for a
	///                         dependency.
	/// dependenciesForDependency - Loads the dependencies for a specific
	///                             version of a dependency.
	/// resolvedGitReference - Resolves an arbitrary Git reference to the
	///                        latest object.
	public init(
		versionsForDependency: @escaping (Dependency) -> SignalProducer<PinnedVersion, CarthageError>,
		dependenciesForDependency: @escaping (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>,
		resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
	) {
		self.versionsForDependency = versionsForDependency
		self.dependenciesForDependency = dependenciesForDependency
		self.resolvedGitReference = resolvedGitReference
	}

  /// Attempts to determine the latest valid version to use for each
  /// dependency in `dependencies`, and all nested dependencies thereof.
  ///
  /// Sends a dictionary with each dependency and its resolved version.
	public func resolve(
		dependencies: [Dependency : VersionSpecifier],
		lastResolved: [Dependency : PinnedVersion]?,
		dependenciesToUpdate: [String]?
	) -> SignalProducer<[Dependency : PinnedVersion], CarthageError> {
    resolve(
      with: initialState(
        from: buildRequirements(from: dependencies, lastResolved: lastResolved, dependenciesToUpdate: dependenciesToUpdate),
        filter: buildFilter(lastResolved: lastResolved, dependenciesToUpdate: dependenciesToUpdate)
      )
    )
    .map(\.resolved)
	}

  /// Main depenedency resolution cycle.
  ///
  /// On each iteration the routine attempts to select candidates from the list of yet unresolved dependencies and process
  /// them. If the list of candidates is empty, returns a terminal state to the caller — state which contains a list of resolved
  /// dependencies.
  ///
  /// - Parameter state: State after the last iteration.
  /// - Returns: `SignalProducer` that emits either a new `state` or `CarthageError`
  /// - Precondition: `state` with an empty list of `candidates`
  /// - Postcondition: `state` with an updated list of `resolved` dependencies and `reuiqrements`
  private func resolve(with state: SimpleResolverState) -> SignalProducer<SimpleResolverState, CarthageError> {
    state
      .selectCandidates(versionsForDependency: versionsForDependency, resolvedGitReference: resolvedGitReference)
      .flatMap(.concat) {
        $0.candidates.isEmpty ? self.postprocess(state: $0) : self.process(state: $0)
      }
  }

  /// Iteration body
  ///
  /// The routine processes `candidates`, updates `resolved` dependencies
  /// and `requirements` and recursively calls `resolve` with updated `state`.
  ///
  /// - Parameter state: state with selected candidates
  /// - Returns: `SignalProducer` that emits either a new `state` or `CarthageError`
  /// - Precondition: `candidates` list is not empty
  /// - Postcondition: `candidates` list is empty
  private func process(state: SimpleResolverState) -> SignalProducer<SimpleResolverState, CarthageError> {
    precondition(!state.candidates.isEmpty)
    return state
      .processCandidates(with: dependenciesForDependency, resolvedGitReference: resolvedGitReference)
      .flatMap(.concat) { $0.updateResolved() }
      .flatMap(.concat) { self.resolve(with: $0) }
  }

  /// Recursion termination routine.
  ///
  /// - Parameter state: a state with a list of resolved dependencies
  /// - Returns: `SignalProducer` that emits passed `state`
  /// - Precondition: `candidates` list is empty
  private func postprocess(state: SimpleResolverState) -> SignalProducer<SimpleResolverState, CarthageError> {
    precondition(state.candidates.isEmpty)
    return SignalProducer(value: state)
  }

  /// Creates initial state.
  ///
  /// - Parameter requirements: initial requirements
  /// - Parameter filter: routine for algorithm adjustment
  /// - Returns: initial `state`
  private func initialState(
    from requirements: DependencyRequirements,
    filter: @escaping (DependencyDescriptor, VersionSpecifier) -> Bool
  ) -> SimpleResolverState {
    return SimpleResolverState(
      candidates: [],
      requirements: requirements,
      resolved: [:],
      filter: filter
    )
  }

  /// Builds `requirements` for initial `state`
  ///
  /// If `dependenciesToUpdate` are `nil` or `Empty` the initial requirements are
  /// built from `dependencies`. Otherwise some filtering applied to resolve
  /// only requested dependencies.
  ///
  /// - Parameter dependencies: list of dependencies from the root `Cartfile`
  /// - Parameter lastResolved: list of previousely resolved dependencies
  /// - Parameter dependenciesToUpdate: list of dependencies to resolve
  /// - Returns: `requirements` for initial `state`.
  private func buildRequirements(
    from dependencies: [Dependency : VersionSpecifier],
    lastResolved: [Dependency : PinnedVersion]?,
    dependenciesToUpdate: [String]?
  ) -> DependencyRequirements {
    guard
      let lastResolved = lastResolved,
      let dependenciesToUpdate = dependenciesToUpdate.map(Set.init),
      !lastResolved.isEmpty,
      !dependenciesToUpdate.isEmpty
    else {
      return DependencyRequirements(dependencies: dependencies)
    }

    return DependencyRequirements(dependencies: dependencies.filter {
      lastResolved.keys.contains($0.key) || dependenciesToUpdate.contains($0.key.name)
    })
  }

  /// Builds `filter` routine for algorithm adjustment and tuning.
  ///
  /// If `dependenciesToUpdate` are `nil` or `Empty` the initial `filter`
  /// routine simply check if dependency satisfies the specifier.
  /// Otherwise some adjustment applied to preserve the version of dependencies
  /// missing in `dependenciesToUpdate` list.
  ///
  /// - Parameter lastResolved: list of previousely resolved dependencies
  /// - Parameter dependenciesToUpdate: list of dependencies to resolve
  /// - Returns: `filter` for initial `state`
  private func buildFilter(
    lastResolved: [Dependency : PinnedVersion]?,
    dependenciesToUpdate: [String]?
  ) -> (DependencyDescriptor, VersionSpecifier) -> Bool {
    guard
      let lastResolved = lastResolved,
      let dependenciesToUpdate = dependenciesToUpdate.map(Set.init),
      !lastResolved.isEmpty,
      !dependenciesToUpdate.isEmpty
    else {
      return defaultFiler
    }

    return { descriptor, specifier in
      if dependenciesToUpdate.contains(descriptor.dependency.name) {
        return specifier.isSatisfied(by: descriptor.version)
      }

      if let lastResolvedVersion = lastResolved[descriptor.dependency],
         specifier.isSatisfied(by: lastResolvedVersion) {
        return descriptor.version == lastResolvedVersion
      } else {
        return specifier.isSatisfied(by: descriptor.version)
      }
    }
  }
}

/// Default `filter` routine which simply check if dependency satisfies `specifier`
private let defaultFiler: (DependencyDescriptor, VersionSpecifier) -> Bool = { $1.isSatisfied(by: $0.version) }
