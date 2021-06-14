import Foundation
import Result
import ReactiveSwift
import Commandant

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

internal struct DependencyRequirement {
  internal let specifier: VersionSpecifier
  internal let constraintor: Dependency?
}

internal struct DependencyRequirements {
  private var storage: [Dependency: DependencyRequirement]

  fileprivate init(storage: [Dependency: DependencyRequirement]) {
    self.storage = storage
  }

  init(dependencies: [Dependency : VersionSpecifier]) {
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

internal struct SimpleResolverState {
  internal let candidates: Set<DependencyDescriptor>
  internal let requirements: DependencyRequirements
  internal let resolved: [Dependency : PinnedVersion]
}

extension SimpleResolverState {
  internal func processCandidates(
    with dependenciesForDependency: @escaping (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  ) -> SignalProducer<SimpleResolverState, CarthageError> {
    collectDependencies(
      for: candidates,
      dependenciesForDependency: dependenciesForDependency,
      resolvedGitReference: resolvedGitReference
    )
    .attemptMap { dependencyMap in
      Result(catching: {
        var newRequirements = requirements
        for (dependency, requirements) in dependencyMap {
          try newRequirements.merge(with: requirements, requiredBy: dependency)
        }
        return SimpleResolverState(candidates: candidates, requirements: newRequirements, resolved: resolved)
      })
    }
  }

  internal func processResolved() -> SignalProducer<SimpleResolverState, CarthageError> {
    SignalProducer(value: self)
      .map { state in
        let allDependencies = state.resolved.map { DependencyDescriptor(dependency: $0, version: $1) } + candidates
        let resolved = allDependencies
          .filter { requirements.versionSpecifier(for: $0.dependency).isSatisfied(by: $0.version) }
          .reduce(into: [:]) { result, descriptor in result[descriptor.dependency] = descriptor.version }
        return SimpleResolverState(candidates: [], requirements: requirements, resolved: resolved)
      }
  }

  internal func selectCandidates(
    versionsForDependency: @escaping (Dependency) -> SignalProducer<PinnedVersion, CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  ) -> SignalProducer<SimpleResolverState, CarthageError> {
    SignalProducer(value: self)
      .flatMap(.concat) { state in
        state.selectCandidates(
          for: state.requirements.dependencies.subtracting(state.resolved.keys),
          versionsForDependency: versionsForDependency,
          resolvedGitReference: resolvedGitReference
        )
        .map { SimpleResolverState(candidates: $0, requirements: state.requirements, resolved: state.resolved) }
      }
  }

  private func collectAvailableVersions(
    for dependency: Dependency,
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

  private func selectCandidate(
    for dependency: Dependency,
    availableVersions: [PinnedVersion]
  ) -> SignalProducer<DependencyDescriptor, CarthageError> {
    SignalProducer(availableVersions)
      .map { DependencyDescriptor(dependency: dependency, version: $0) }
      .collect()
      .map { $0.sorted()[0] }
  }

  private func selectCandidates(
    for dependencies: Set<Dependency>,
    versionsForDependency: @escaping (Dependency) -> SignalProducer<PinnedVersion, CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  ) -> SignalProducer<Set<DependencyDescriptor>, CarthageError> {
    SignalProducer(dependencies)
      .flatMap(.merge) { dependency -> SignalProducer<DependencyDescriptor, CarthageError> in
        return self.collectAvailableVersions(
          for: dependency,
          versionsForDependency: versionsForDependency,
          resolvedGitReference: resolvedGitReference
        )
        .flatMap(.merge) {
          self.selectCandidate(for: dependency, availableVersions: $0)
        }
      }
      .collect()
      .map(Set.init)
  }

  private func collectDependencies(
    for dependencies: Set<DependencyDescriptor>,
    dependenciesForDependency: @escaping (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>,
    resolvedGitReference: @escaping (Dependency, String) -> SignalProducer<PinnedVersion, CarthageError>
  ) -> SignalProducer<[Dependency : [(Dependency, VersionSpecifier)]], CarthageError> {
    SignalProducer(dependencies)
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
        var dependencyMap = [Dependency : [(Dependency, VersionSpecifier)]]()
        for (descriptor, dependency, specifier) in collection {
          dependencyMap[descriptor.dependency, default: []].append((dependency, specifier))
        }
        return dependencyMap
      }
  }
}

/// Responsible for resolving acyclic dependency graphs.
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

	public func resolve(
		dependencies: [Dependency : VersionSpecifier],
		lastResolved: [Dependency : PinnedVersion]?,
		dependenciesToUpdate: [String]?
	) -> SignalProducer<[Dependency : PinnedVersion], CarthageError> {
    return resolve(with: initialState(from: dependencies, lastResolved: lastResolved ?? [:]))
      .map(\.resolved)
	}

  private func resolve(with state: SimpleResolverState) -> SignalProducer<SimpleResolverState, CarthageError> {
    state
      .selectCandidates(versionsForDependency: versionsForDependency, resolvedGitReference: resolvedGitReference)
      .flatMap(.concat) {
        $0.candidates.isEmpty ? self.postprocess(state: $0) : self.process(state: $0)
      }
  }

  private func process(state: SimpleResolverState) -> SignalProducer<SimpleResolverState, CarthageError> {
    state.processCandidates(with: dependenciesForDependency, resolvedGitReference: resolvedGitReference)
      .flatMap(.concat) { $0.processResolved() }
      .flatMap(.concat) { self.resolve(with: $0) }
  }

  private func postprocess(state: SimpleResolverState) -> SignalProducer<SimpleResolverState, CarthageError> {
    SignalProducer(value: state)
  }

  private func initialState(
    from dependencies: [Dependency : VersionSpecifier],
    lastResolved: [Dependency : PinnedVersion]
  ) -> SimpleResolverState {
    let requirements = DependencyRequirements(dependencies: dependencies)
    return SimpleResolverState(
      candidates: [],
      requirements: requirements,
      resolved: [:]
    )
  }
}
