// swiftlint:disable file_length

import CommonCrypto
import Foundation
import ReactiveSwift
import ReactiveTask
import Result
import Tentacle
import XCDBLD

/// Describes an event occurring to or with a project.
public enum ProjectEvent {
  /// The project is beginning to clone.
  case cloning(Dependency)

  /// The project is beginning a fetch.
  case fetching(Dependency)

  /// The project is being checked out to the specified revision.
  case checkingOut(Dependency, String)

  /// The project is downloading a binary-only framework definition.
  case downloadingBinaryFrameworkDefinition(Dependency, URL)

  /// Any available binaries for the specified release of the project are
  /// being downloaded. This may still be followed by `CheckingOut` event if
  /// there weren't any viable binaries after all.
  case downloadingBinaries(Dependency, String)

  /// Downloading any available binaries of the project is being skipped,
  /// because of a GitHub API request failure which is due to authentication
  /// or rate-limiting.
  case skippedDownloadingBinaries(Dependency, String)

  /// Installing of a binary framework is being skipped because of an inability
  /// to verify that it was built with a compatible Swift version.
  case skippedInstallingBinaries(dependency: Dependency, error: Error)

  /// Building the project is being skipped, since the project is not sharing
  /// any framework schemes.
  case skippedBuilding(Dependency, String)

  /// Building the project is being skipped because it is cached.
  case skippedBuildingCached(Dependency)

  /// Rebuilding a cached project because of a version file/framework mismatch.
  case rebuildingCached(Dependency)

  /// Building an uncached project.
  case buildingUncached(Dependency)
}

extension ProjectEvent: Equatable {
  public static func == (lhs: ProjectEvent, rhs: ProjectEvent) -> Bool {
    switch (lhs, rhs) {
      case let (.cloning(left), .cloning(right)):
        return left == right

      case let (.fetching(left), .fetching(right)):
        return left == right

      case let (.checkingOut(leftIdentifier, leftRevision), .checkingOut(rightIdentifier, rightRevision)):
        return leftIdentifier == rightIdentifier && leftRevision == rightRevision

      case let (.downloadingBinaryFrameworkDefinition(leftIdentifier, leftURL), .downloadingBinaryFrameworkDefinition(rightIdentifier, rightURL)):
        return leftIdentifier == rightIdentifier && leftURL == rightURL

      case let (.downloadingBinaries(leftIdentifier, leftRevision), .downloadingBinaries(rightIdentifier, rightRevision)):
        return leftIdentifier == rightIdentifier && leftRevision == rightRevision

      case let (.skippedDownloadingBinaries(leftIdentifier, leftRevision), .skippedDownloadingBinaries(rightIdentifier, rightRevision)):
        return leftIdentifier == rightIdentifier && leftRevision == rightRevision

      case let (.skippedBuilding(leftIdentifier, leftRevision), .skippedBuilding(rightIdentifier, rightRevision)):
        return leftIdentifier == rightIdentifier && leftRevision == rightRevision

      default:
        return false
    }
  }
}

/// Represents a project that is using Carthage.
public final class Project { // swiftlint:disable:this type_body_length
  /// File URL to the root directory of the project.
  public let directoryURL: URL

  /// The file URL to the project's Cartfile.
  public var cartfileURL: URL {
    return directoryURL.appendingPathComponent(Constants.Project.cartfilePath, isDirectory: false)
  }

  /// The file URL to the project's Cartfile.resolved.
  public var resolvedCartfileURL: URL {
    return directoryURL.appendingPathComponent(Constants.Project.resolvedCartfilePath, isDirectory: false)
  }

  /// Whether to prefer HTTPS for cloning (vs. SSH).
  public var preferHTTPS = true

  /// Whether to use submodules for dependencies, or just check out their
  /// working directories.
  public var useSubmodules = false

  /// Whether to use authentication credentials from ~/.netrc file
  /// to download binary only frameworks.
  public var useNetrc = false

  /// Sends each event that occurs to a project underneath the receiver (or
  /// the receiver itself).
  public let projectEvents: Signal<ProjectEvent, Never>
  private let _projectEventsObserver: Signal<ProjectEvent, Never>.Observer

  public init(directoryURL: URL) {
    precondition(directoryURL.isFileURL)

    let (signal, observer) = Signal<ProjectEvent, Never>.pipe()
    projectEvents = signal
    self._projectEventsObserver = observer

    self.directoryURL = directoryURL
  }

  private typealias CachedVersions = [Dependency: [PinnedVersion]]
  private typealias CachedBinaryProjects = [URL: BinaryProject]

  /// Caches versions to avoid expensive lookups, and unnecessary
  /// fetching/cloning.
  private var cachedVersions: CachedVersions = [:]
  private let cachedVersionsQueue = SerialProducerQueue(name: "org.utica.Constants.Project.cachedVersionsQueue")

  // Cache the binary project definitions in memory to avoid redownloading during utica operation
  private var cachedBinaryProjects: CachedBinaryProjects = [:]
  private let cachedBinaryProjectsQueue = SerialProducerQueue(name: "org.utica.Constants.Project.cachedBinaryProjectsQueue")

  private lazy var xcodeVersionDirectory: String = XcodeVersion.make()
    .map { "\($0.version)_\($0.buildVersion)" } ?? "Unknown"

  /// Attempts to load Cartfile or Cartfile.private from the given directory,
  /// merging their dependencies.
  public func loadCombinedCartfile() -> SignalProducer<Cartfile, CarthageError> {
    let cartfileURL = directoryURL.appendingPathComponent(Constants.Project.cartfilePath, isDirectory: false)
    let privateCartfileURL = directoryURL.appendingPathComponent(Constants.Project.privateCartfilePath, isDirectory: false)

    func isNoSuchFileError(_ error: CarthageError) -> Bool {
      switch error {
        case let .readFailed(_, underlyingError):
          if let underlyingError = underlyingError {
            return underlyingError.domain == NSCocoaErrorDomain && underlyingError.code == NSFileReadNoSuchFileError
          } else {
            return false
          }

        default:
          return false
      }
    }

    let cartfile = SignalProducer { Cartfile.from(file: cartfileURL) }
      .flatMapError { error -> SignalProducer<Cartfile, CarthageError> in
        if isNoSuchFileError(error), FileManager.default.fileExists(atPath: privateCartfileURL.path) {
          return SignalProducer(value: Cartfile())
        }

        return SignalProducer(error: error)
      }

    let privateCartfile = SignalProducer { Cartfile.from(file: privateCartfileURL) }
      .flatMapError { error -> SignalProducer<Cartfile, CarthageError> in
        if isNoSuchFileError(error) {
          return SignalProducer(value: Cartfile())
        }

        return SignalProducer(error: error)
      }

    return SignalProducer.zip(cartfile, privateCartfile)
      .attemptMap { cartfile, privateCartfile -> Result<Cartfile, CarthageError> in
        var cartfile = cartfile

        let duplicateDeps = duplicateDependenciesIn(cartfile, privateCartfile).map { dependency in
          DuplicateDependency(
            dependency: dependency,
            locations: ["\(Constants.Project.cartfilePath)", "\(Constants.Project.privateCartfilePath)"]
          )
        }

        if duplicateDeps.isEmpty {
          cartfile.append(privateCartfile)
          return .success(cartfile)
        }

        return .failure(.duplicateDependencies(duplicateDeps))
      }
  }

  /// Reads the project's Cartfile.resolved.
  public func loadResolvedCartfile() -> SignalProducer<ResolvedCartfile, CarthageError> {
    return SignalProducer {
      Result(catching: { try String(contentsOf: self.resolvedCartfileURL, encoding: .utf8) })
        .mapError { .readFailed(self.resolvedCartfileURL, $0) }
        .flatMap(ResolvedCartfile.from)
    }
  }

  /// Writes the given Cartfile.resolved out to the project's directory.
  public func writeResolvedCartfile(_ resolvedCartfile: ResolvedCartfile) -> Result<Void, CarthageError> {
    return Result(at: resolvedCartfileURL, attempt: {
      try resolvedCartfile.description.write(to: $0, atomically: true, encoding: .utf8)
    })
  }

  /// Limits the number of concurrent clones/fetches to the number of active
  /// processors.
  private let cloneOrFetchQueue = ConcurrentProducerQueue(name: "org.utica.UticaKit", limit: ProcessInfo.processInfo.activeProcessorCount)

  /// Clones the given dependency to the global repositories folder, or fetches
  /// inside it if it has already been cloned.
  ///
  /// Returns a signal which will send the URL to the repository's folder on
  /// disk once cloning or fetching has completed.
  private func cloneOrFetchDependency(_ dependency: Dependency, commitish: String? = nil) -> SignalProducer<URL, CarthageError> {
    return cloneOrFetch(dependency: dependency, preferHTTPS: preferHTTPS, commitish: commitish)
      .on(value: { event, _ in
        if let event = event {
          self._projectEventsObserver.send(value: event)
        }
      })
      .map { _, url in url }
      .take(last: 1)
      .startOnQueue(cloneOrFetchQueue)
  }

  func downloadBinaryFrameworkDefinition(binary: BinaryURL) -> SignalProducer<BinaryProject, CarthageError> {
    return SignalProducer<Project.CachedBinaryProjects, CarthageError>(value: cachedBinaryProjects)
      .flatMap(.merge) { binaryProjectsByURL -> SignalProducer<BinaryProject, CarthageError> in
        if let binaryProject = binaryProjectsByURL[binary.url] {
          return SignalProducer(value: binaryProject)
        } else {
          self._projectEventsObserver.send(value: .downloadingBinaryFrameworkDefinition(.binary(binary), binary.url))

          let request = self.buildURLRequest(for: binary.url, useNetrc: self.useNetrc)
          return URLSession.proxiedSession.reactive.data(with: request)
            .mapError { CarthageError.readFailed(binary.url, $0 as NSError) }
            .attemptMap { data, _ in
              BinaryProject.from(jsonData: data).mapError { error in
                CarthageError.invalidBinaryJSON(binary.url, error)
              }
            }
            .on(value: { binaryProject in
              self.cachedBinaryProjects[binary.url] = binaryProject
            })
        }
      }
      .startOnQueue(cachedBinaryProjectsQueue)
  }

  /// Builds URL request
  ///
  /// - Parameters:
  ///   - url: a url that identifies the location of a resource
  ///   - useNetrc: determines whether to use credentials from `~/.netrc` file
  /// - Returns: a URL request
  private func buildURLRequest(for url: URL, useNetrc: Bool) -> URLRequest {
    var request = URLRequest(url: url)
    guard useNetrc else { return request }

    // When downloading a binary, `utica` will take into account the user's
    // `~/.netrc` file to determine authentication credentials
    switch Netrc.load() {
      case let .success(netrc):
        if let authorization = netrc.authorization(for: url) {
          request.addValue(authorization, forHTTPHeaderField: "Authorization")
        }
      case .failure: break // Do nothing
    }
    return request
  }

  /// Sends all versions available for the given project.
  ///
  /// This will automatically clone or fetch the project's repository as
  /// necessary.
  private func versions(for dependency: Dependency) -> SignalProducer<PinnedVersion, CarthageError> {
    let fetchVersions: SignalProducer<PinnedVersion, CarthageError>

    switch dependency {
      case .git, .gitHub:
        fetchVersions = cloneOrFetchDependency(dependency)
          .flatMap(.merge) { repositoryURL in listTags(repositoryURL) }
          .map { PinnedVersion($0) }

      case let .binary(binary):
        fetchVersions = downloadBinaryFrameworkDefinition(binary: binary)
          .flatMap(.concat) { binaryProject -> SignalProducer<PinnedVersion, CarthageError> in
            SignalProducer(binaryProject.versions.keys)
          }
    }

    return SignalProducer<Project.CachedVersions, CarthageError>(value: cachedVersions)
      .flatMap(.merge) { versionsByDependency -> SignalProducer<PinnedVersion, CarthageError> in
        if let versions = versionsByDependency[dependency] {
          return SignalProducer(versions)
        } else {
          return fetchVersions
            .collect()
            .on(value: { newVersions in
              self.cachedVersions[dependency] = newVersions
            })
            .flatMap(.concat) { versions in SignalProducer<PinnedVersion, CarthageError>(versions) }
        }
      }
      .startOnQueue(cachedVersionsQueue)
      .collect()
      .flatMap(.concat) { versions -> SignalProducer<PinnedVersion, CarthageError> in
        if versions.isEmpty {
          return SignalProducer(error: .taggedVersionNotFound(dependency))
        }

        return SignalProducer(versions)
      }
  }

  /// Produces the sub dependencies of the given dependency. Uses the checked out directory if able
  private func dependencySet(for dependency: Dependency, version: PinnedVersion) -> SignalProducer<Set<Dependency>, CarthageError> {
    return dependencies(for: dependency, version: version, tryCheckoutDirectory: true)
      .map { $0.0 }
      .collect()
      .map { Set($0) }
      .concat(value: Set())
      .take(first: 1)
  }

  /// Loads the dependencies for the given dependency, at the given version.
  private func dependencies(for dependency: Dependency, version: PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
    return dependencies(for: dependency, version: version, tryCheckoutDirectory: false)
  }

  /// Loads the dependencies for the given dependency, at the given version. Optionally can attempt to read from the Checkout directory
  private func dependencies(
    for dependency: Dependency,
    version: PinnedVersion,
    tryCheckoutDirectory: Bool
  ) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> {
    switch dependency {
      case .git, .gitHub:
        let revision = version.commitish
        let cartfileFetch: SignalProducer<Cartfile, CarthageError> = cloneOrFetchDependency(dependency, commitish: revision)
          .flatMap(.concat) { repositoryURL in
            contentsOfFileInRepository(repositoryURL, Constants.Project.cartfilePath, revision: revision)
          }
          .flatMapError { _ in .empty }
          .attemptMap(Cartfile.from(string:))

        let cartfileSource: SignalProducer<Cartfile, CarthageError>
        if tryCheckoutDirectory {
          let dependencyURL = directoryURL.appendingPathComponent(dependency.relativePath)
          cartfileSource = SignalProducer<Bool, Never> { () -> Bool in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: dependencyURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
          }
          .flatMap(.concat) { directoryExists -> SignalProducer<Cartfile, CarthageError> in
            if directoryExists {
              return SignalProducer(result: Cartfile.from(file: dependencyURL.appendingPathComponent(Constants.Project.cartfilePath)))
                .flatMapError { _ in .empty }
            } else {
              return cartfileFetch
            }
          }
          .flatMapError { _ in .empty }
        } else {
          cartfileSource = cartfileFetch
        }
        return cartfileSource
          .flatMap(.concat) { cartfile -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> in
            SignalProducer(cartfile.dependencies.map { ($0.0, $0.1) })
          }

      case .binary:
        // Binary-only frameworks do not support dependencies
        return .empty
    }
  }

  /// Finds all the transitive dependencies for the dependencies to checkout.
  func transitiveDependencies(
    _ dependenciesToCheckout: [String]?,
    resolvedCartfile: ResolvedCartfile
  ) -> SignalProducer<[String], CarthageError> {
    return SignalProducer(value: resolvedCartfile)
      .map { resolvedCartfile -> [(Dependency, PinnedVersion)] in
        resolvedCartfile.dependencies
          .filter { dep, _ in dependenciesToCheckout?.contains(dep.name) ?? false }
      }
      .flatMap(.merge) { dependencies -> SignalProducer<[String], CarthageError> in
        SignalProducer<(Dependency, PinnedVersion), CarthageError>(dependencies)
          .flatMap(.merge) { dependency, version -> SignalProducer<(Dependency, VersionSpecifier), CarthageError> in
            self.dependencies(for: dependency, version: version)
          }
          .map { $0.0.name }
          .collect()
      }
  }

  /// Finds the required dependencies and their corresponding version specifiers for each dependency in Cartfile.resolved.
  func requirementsByDependency(
    resolvedCartfile: ResolvedCartfile,
    tryCheckoutDirectory: Bool
  ) -> SignalProducer<CompatibilityInfo.Requirements, CarthageError> {
    return SignalProducer(resolvedCartfile.dependencies)
      .flatMap(.concurrent(limit: 4)) { dependency, pinnedVersion -> SignalProducer<(Dependency, (Dependency, VersionSpecifier)), CarthageError> in
        self.dependencies(for: dependency, version: pinnedVersion, tryCheckoutDirectory: tryCheckoutDirectory)
          .map { (dependency, $0) }
      }
      .collect()
      .flatMap(.merge) { dependencyAndRequirements -> SignalProducer<CompatibilityInfo.Requirements, CarthageError> in
        var dict: CompatibilityInfo.Requirements = [:]
        for (dependency, requirement) in dependencyAndRequirements {
          let (requiredDependency, requiredVersion) = requirement
          var requirementsDict = dict[dependency] ?? [:]

          if requirementsDict[requiredDependency] != nil {
            return SignalProducer(error: .duplicateDependencies([DuplicateDependency(dependency: requiredDependency, locations: [])]))
          }

          requirementsDict[requiredDependency] = requiredVersion
          dict[dependency] = requirementsDict
        }
        return SignalProducer(value: dict)
      }
  }

  /// Attempts to resolve a Git reference to a version.
  private func resolvedGitReference(_ dependency: Dependency, reference: String) -> SignalProducer<PinnedVersion, CarthageError> {
    let repositoryURL = repositoryFileURL(for: dependency)
    return cloneOrFetchDependency(dependency, commitish: reference)
      .flatMap(.concat) { _ in
        resolveTagInRepository(repositoryURL, reference)
          .map { _ in
            // If the reference is an exact tag, resolves it to the tag.
            PinnedVersion(reference)
          }
          .flatMapError { _ in
            resolveReferenceInRepository(repositoryURL, reference)
              .map(PinnedVersion.init)
          }
      }
  }

  /// Attempts to determine the latest satisfiable version of the project's
  /// Carthage dependencies.
  ///
  /// This will fetch dependency repositories as necessary, but will not check
  /// them out into the project's working directory.
  public func updatedResolvedCartfile(_ dependenciesToUpdate: [String]? = nil, resolver: Resolver) -> SignalProducer<ResolvedCartfile, CarthageError> {
    let resolvedCartfile: SignalProducer<ResolvedCartfile?, CarthageError> = loadResolvedCartfile()
      .map(Optional.init)
      .flatMapError { _ in .init(value: nil) }

    return SignalProducer
      .zip(loadCombinedCartfile(), resolvedCartfile)
      .flatMap(.merge) { cartfile, resolvedCartfile in
        resolver.resolve(
          dependencies: cartfile.dependencies,
          lastResolved: resolvedCartfile?.dependencies ?? [:],
          dependenciesToUpdate: dependenciesToUpdate ?? []
        )
      }
      .map(ResolvedCartfile.init)
  }

  /// Attempts to determine the latest version (whether satisfiable or not)
  /// of the project's Carthage dependencies.
  ///
  /// This will fetch dependency repositories as necessary, but will not check
  /// them out into the project's working directory.
  private func latestDependencies(resolver: Resolver) -> SignalProducer<[Dependency: PinnedVersion], CarthageError> {
    func resolve(prefersGitReference: Bool) -> SignalProducer<[Dependency: PinnedVersion], CarthageError> {
      return SignalProducer
        .combineLatest(loadCombinedCartfile(), loadResolvedCartfile())
        .map { cartfile, resolvedCartfile in
          resolvedCartfile
            .dependencies
            .reduce(into: [Dependency: VersionSpecifier]()) { result, group in
              let dependency = group.key
              let specifier: VersionSpecifier
              if case let .gitReference(value)? = cartfile.dependencies[dependency], prefersGitReference {
                specifier = .gitReference(value)
              } else {
                specifier = .any
              }
              result[dependency] = specifier
            }
        }
        .flatMap(.merge) { resolver.resolve(dependencies: $0, lastResolved: [:], dependenciesToUpdate: []) }
    }

    return resolve(prefersGitReference: false).flatMapError { error in
      switch error {
        case .taggedVersionNotFound:
          return resolve(prefersGitReference: true)
        default:
          return SignalProducer(error: error)
      }
    }
  }

  public typealias OutdatedDependency = (Dependency, PinnedVersion, PinnedVersion, PinnedVersion)
  /// Attempts to determine which of the project's Carthage
  /// dependencies are out of date.
  ///
  /// This will fetch dependency repositories as necessary, but will not check
  /// them out into the project's working directory.
  public func outdatedDependencies(_ includeNestedDependencies: Bool, resolver: Resolver? = nil) -> SignalProducer<[OutdatedDependency], CarthageError> {
    let dependencies: (Dependency, PinnedVersion) -> SignalProducer<(Dependency, VersionSpecifier), CarthageError>
    if includeNestedDependencies {
      dependencies = self.dependencies(for:version:)
    } else {
      dependencies = { _, _ in .empty }
    }

    let resolver = resolver ?? SimpleResolver(
      versionsForDependency: versions(for:),
      dependenciesForDependency: dependencies,
      resolvedGitReference: resolvedGitReference
    )

    let outdatedDependencies = SignalProducer
      .combineLatest(
        loadResolvedCartfile(),
        updatedResolvedCartfile(resolver: resolver),
        latestDependencies(resolver: resolver)
      )
      .map { ($0.dependencies, $1.dependencies, $2) }
      .map { currentDependencies, updatedDependencies, latestDependencies -> [OutdatedDependency] in
        updatedDependencies.compactMap { project, version -> OutdatedDependency? in
          if let resolved = currentDependencies[project], let latest = latestDependencies[project], resolved != version || resolved != latest {
            if SemanticVersion.from(resolved).value == nil, version == resolved {
              // If resolved version is not a semantic version but a commit
              // it is a false-positive if `version` and `resolved` are the same
              return nil
            }

            return (project, resolved, version, latest)
          } else {
            return nil
          }
        }
      }

    if includeNestedDependencies {
      return outdatedDependencies
    }

    return SignalProducer
      .combineLatest(
        outdatedDependencies,
        loadCombinedCartfile()
      )
      .map { oudatedDependencies, combinedCartfile -> [OutdatedDependency] in
        oudatedDependencies.filter { project, _, _, _ in
          combinedCartfile.dependencies[project] != nil
        }
      }
  }

  /// Updates the dependencies of the project to the latest version. The
  /// changes will be reflected in Cartfile.resolved, and also in the working
  /// directory checkouts if the given parameter is true.
  public func updateDependencies(
    shouldCheckout: Bool = true,
    buildOptions: BuildOptions,
    dependenciesToUpdate: [String]? = nil
  ) -> SignalProducer<Void, CarthageError> {
    let resolver = SimpleResolver(
      versionsForDependency: versions(for:),
      dependenciesForDependency: dependencies,
      resolvedGitReference: resolvedGitReference
    )

    return updatedResolvedCartfile(dependenciesToUpdate, resolver: resolver)
      .attemptMap { resolvedCartfile -> Result<Void, CarthageError> in
        self.writeResolvedCartfile(resolvedCartfile)
      }
      .then(shouldCheckout ? checkoutResolvedDependencies(dependenciesToUpdate, buildOptions: buildOptions) : .empty)
  }

  /// Constructs the file:// URL at which a given .framework or .xcframework
  /// will be found. Depends on the location of the current project.
  private func frameworkURLInCarthageBuildFolder(
    forSDK sdk: SDK,
    frameworkNameAndExtension: String
  ) -> Result<URL, CarthageError> {
    guard let destinationURLInWorkingDir = sdk
      .relativeURL?
      .appendingPathComponent(frameworkNameAndExtension, isDirectory: true)
    else {
      return .failure(.internalError(description: "failed to construct framework destination url from \(sdk.platformSimulatorlessFromHeuristic) and \(frameworkNameAndExtension)"))
    }

    return .success(directoryURL
      .appendingPathComponent(destinationURLInWorkingDir.path, isDirectory: true)
      .standardizedFileURL)
  }

  /// Unzips the file at the given URL and copies the frameworks, DSYM and
  /// bcsymbolmap files into the corresponding folders for the project. This
  /// step will also check framework compatibility and create a version file
  /// for the given frameworks.
  ///
  /// Sends the temporary URL of the unzipped directory
  private func unarchiveAndCopyBinaryFrameworks(
    zipFile: URL,
    projectName: String,
    pinnedVersion: PinnedVersion,
    toolchain: String?
  ) -> SignalProducer<URL, CarthageError> {
    // Helper type
    typealias SourceURLAndDestinationURL = (frameworkSourceURL: URL, frameworkDestinationURL: URL)

    // Returns the unique pairs in the input array
    // or the duplicate keys by .frameworkDestinationURL
    func uniqueSourceDestinationPairs(
      _ sourceURLAndDestinationURLpairs: [SourceURLAndDestinationURL]
    ) -> Result<[SourceURLAndDestinationURL], CarthageError> {
      let destinationMap = sourceURLAndDestinationURLpairs
        .reduce(into: [URL: [URL]]()) { result, pair in
          result[pair.frameworkDestinationURL] =
            (result[pair.frameworkDestinationURL] ?? []) + [pair.frameworkSourceURL]
        }

      let dupes = destinationMap.filter { $0.value.count > 1 }
      guard dupes.count == 0 else {
        return .failure(CarthageError
          .duplicatesInArchive(duplicates: CarthageError
            .DuplicatesInArchive(dictionary: dupes)))
      }

      let uniquePairs = destinationMap
        .filter { $0.value.count == 1 }
        .map { SourceURLAndDestinationURL(
          frameworkSourceURL: $0.value.first!,
          frameworkDestinationURL: $0.key
        ) }
      return .success(uniquePairs)
    }

    return SignalProducer<URL, CarthageError>(value: zipFile)
      .flatMap(.concat, unarchive(archive:))
      .flatMap(.concat) { directoryURL -> SignalProducer<URL, CarthageError> in
        // For all frameworks in the directory where the archive has been expanded
        frameworksInDirectory(directoryURL)
          .collect()
          // Check if multiple frameworks resolve to the same unique destination URL in the Carthage/Build/ folder.
          // This is needed because frameworks might overwrite each others.
          .flatMap(.merge) { frameworksUrls -> SignalProducer<SourceURLAndDestinationURL, CarthageError> in
            SignalProducer<URL, CarthageError>(frameworksUrls)
              .flatMap(.merge) { url -> SignalProducer<URL, CarthageError> in
                self.getBinaryFrameworkURL(url: url)
              }
              .collect()
              .flatMap(.merge) { destinationUrls -> SignalProducer<SourceURLAndDestinationURL, CarthageError> in
                let frameworkUrlAndDestinationUrlPairs = zip(
                  frameworksUrls.map { $0.standardizedFileURL },
                  destinationUrls.map { $0.standardizedFileURL }
                )
                .map { SourceURLAndDestinationURL(
                  frameworkSourceURL: $0,
                  frameworkDestinationURL: $1
                ) }

                return uniqueSourceDestinationPairs(frameworkUrlAndDestinationUrlPairs)
                  .producer
                  .flatMap(.merge) { SignalProducer($0) }
              }
          }
          // Check if the framework are compatible with the current Swift version
          .flatMap(.merge) { pair -> SignalProducer<SourceURLAndDestinationURL, CarthageError> in
            checkFrameworkCompatibility(pair.frameworkSourceURL, usingToolchain: toolchain)
              .then(SignalProducer(value: pair))
          }
          // If the framework is compatible copy it over to the destination folder in Carthage/Build
          .flatMap(.merge) { pair -> SignalProducer<URL, CarthageError> in
            SignalProducer<URL, CarthageError>(value: pair.frameworkSourceURL)
              .copyFileURLsIntoDirectory(pair.frameworkDestinationURL.deletingLastPathComponent())
              .then(SignalProducer<URL, CarthageError>(value: pair.frameworkDestinationURL))
          }
          // Copy .dSYM & .bcsymbolmap too
          .flatMap(.merge) { frameworkDestinationURL -> SignalProducer<URL, CarthageError> in
            guard frameworkDestinationURL.pathExtension != "xcframework" else {
              // xcframeworks have embedded debug information which is not copied out.
              return SignalProducer(value: frameworkDestinationURL)
            }
            return self.copyDSYMToBuildFolderForFramework(frameworkDestinationURL, fromDirectoryURL: directoryURL)
              .then(self.copyBCSymbolMapsToBuildFolderForFramework(frameworkDestinationURL, fromDirectoryURL: directoryURL))
              .then(SignalProducer(value: frameworkDestinationURL))
          }
          .collect()
          // Write the .version file
          .flatMap(.concat) { frameworkURLs -> SignalProducer<Void, CarthageError> in
            self.createVersionFilesForFrameworks(
              frameworkURLs,
              fromDirectoryURL: directoryURL,
              projectName: projectName,
              commitish: pinnedVersion.commitish
            )
          }
          .then(SignalProducer<URL, CarthageError>(value: directoryURL))
      }
  }

  /// Ensures binary framework has a valid extension and returns url in build folder
  private func getBinaryFrameworkURL(url: URL) -> SignalProducer<URL, CarthageError> {
    switch url.pathExtension {
      case "xcframework":
        return SignalProducer<URL, CarthageError>(value: url)
          .map { self.directoryURL.appendingPathComponent(Constants.binariesFolderPath).appendingPathComponent($0.lastPathComponent) }
      default:
        return platformForFramework(url)
          .attemptMap { self.frameworkURLInCarthageBuildFolder(
            forSDK: $0,
            frameworkNameAndExtension: url.lastPathComponent
          ) }
    }
  }

  /// Removes the file located at the given URL
  ///
  /// Sends empty value on successful removal
  private func removeItem(at url: URL) -> SignalProducer<Void, CarthageError> {
    return SignalProducer {
      Result(at: url, attempt: FileManager.default.removeItem(at:))
    }
  }

  /// Installs binaries and debug symbols for the given project, if available.
  ///
  /// Sends a boolean indicating whether binaries were installed.
  private func installBinaries(for dependency: Dependency, pinnedVersion: PinnedVersion, preferXCFrameworks: Bool, toolchain: String?) -> SignalProducer<Bool, CarthageError> {
    switch dependency {
      case let .gitHub(server, repository):
        let client = Client(server: server)
        return downloadMatchingBinaries(
          for: dependency,
          pinnedVersion: pinnedVersion,
          fromRepository: repository,
          preferXCFrameworks: preferXCFrameworks,
          client: client
        )
        .flatMapError { error -> SignalProducer<URL, CarthageError> in
          if !client.isAuthenticated {
            return SignalProducer(error: error)
          }
          return self.downloadMatchingBinaries(
            for: dependency,
            pinnedVersion: pinnedVersion,
            fromRepository: repository,
            preferXCFrameworks: preferXCFrameworks,
            client: Client(server: server, isAuthenticated: false)
          )
        }
        .flatMap(.concat) {
          self.unarchiveAndCopyBinaryFrameworks(zipFile: $0, projectName: dependency.name, pinnedVersion: pinnedVersion, toolchain: toolchain)
        }
        .flatMap(.concat) { self.removeItem(at: $0) }
        .map { true }
        .flatMapError { error in
          self._projectEventsObserver.send(value: .skippedInstallingBinaries(dependency: dependency, error: error))
          return SignalProducer(value: false)
        }
        .concat(value: false)
        .take(first: 1)

      case .git, .binary:
        return SignalProducer(value: false)
    }
  }

  /// Downloads any binaries and debug symbols that may be able to be used
  /// instead of a repository checkout.
  ///
  /// Sends the URL to each downloaded zip, after it has been moved to a
  /// less temporary location.
  private func downloadMatchingBinaries(
    for dependency: Dependency,
    pinnedVersion: PinnedVersion,
    fromRepository repository: Repository,
    preferXCFrameworks: Bool,
    client: Client
  ) -> SignalProducer<URL, CarthageError> {
    return client.execute(repository.release(forTag: pinnedVersion.commitish))
      .map { _, release in release }
      .filter { release in
        !release.isDraft && !release.assets.isEmpty
      }
      .flatMapError { error -> SignalProducer<Release, CarthageError> in
        switch error {
          case .doesNotExist:
            return .empty

          case let .apiError(_, _, error):
            // Log the GitHub API request failure, not to error out,
            // because that should not be fatal error.
            self._projectEventsObserver.send(value: .skippedDownloadingBinaries(dependency, error.message))
            return .empty

          default:
            return SignalProducer(error: .gitHubAPIRequestFailed(error))
        }
      }
      .on(value: { release in
        self._projectEventsObserver.send(value: .downloadingBinaries(dependency, release.nameWithFallback))
      })
      .flatMap(.concat) { release -> SignalProducer<URL, CarthageError> in
        let potentialFrameworkAssets = release.assets.filter { asset in
          let matchesContentType = Constants.Project.binaryAssetContentTypes.contains(asset.contentType)
          let matchesName = asset.name.contains(Constants.Project.frameworkBinaryAssetPattern) || asset.name.contains(Constants.Project.xcframeworkBinaryAssetPattern)
          return matchesContentType && matchesName
        }
        return SignalProducer<Release.Asset, CarthageError>(binaryAssetFilter(prioritizing: potentialFrameworkAssets, preferXCFrameworks: preferXCFrameworks))
          .flatMap(.concat) { asset -> SignalProducer<URL, CarthageError> in
            let fileURL = fileURLToCachedBinary(dependency, release, asset)

            if FileManager.default.fileExists(atPath: fileURL.path) {
              return SignalProducer(value: fileURL)
            } else {
              return client.download(asset: asset)
                .mapError(CarthageError.gitHubAPIRequestFailed)
                .flatMap(.concat) { downloadURL in cacheDownloadedBinary(downloadURL, toURL: fileURL) }
            }
          }
      }
  }

  /// Copies the DSYM matching the given framework and contained within the
  /// given directory URL to the directory that the framework resides within.
  ///
  /// If no dSYM is found for the given framework, completes with no values.
  ///
  /// Sends the URL of the dSYM after copying.
  public func copyDSYMToBuildFolderForFramework(_ frameworkURL: URL, fromDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
    let destinationDirectoryURL = frameworkURL.deletingLastPathComponent()
    return dSYMForFramework(frameworkURL, inDirectoryURL: directoryURL)
      .copyFileURLsIntoDirectory(destinationDirectoryURL)
  }

  /// Copies any *.bcsymbolmap files matching the given framework and contained
  /// within the given directory URL to the directory that the framework
  /// resides within.
  ///
  /// If no bcsymbolmap files are found for the given framework, completes with
  /// no values.
  ///
  /// Sends the URLs of the bcsymbolmap files after copying.
  public func copyBCSymbolMapsToBuildFolderForFramework(_ frameworkURL: URL, fromDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
    let destinationDirectoryURL = frameworkURL.deletingLastPathComponent()
    return BCSymbolMapsForFramework(frameworkURL, inDirectoryURL: directoryURL)
      .copyFileURLsIntoDirectory(destinationDirectoryURL)
  }

  /// Creates a .version file for all of the provided frameworks.
  public func createVersionFilesForFrameworks(
    _ frameworkURLs: [URL],
    fromDirectoryURL _: URL,
    projectName: String,
    commitish: String
  ) -> SignalProducer<Void, CarthageError> {
    return createVersionFileForCommitish(commitish, dependencyName: projectName, buildProducts: frameworkURLs, rootDirectoryURL: directoryURL)
  }

  private let gitOperationQueue = SerialProducerQueue(name: "org.utica.Constants.Project.gitOperationQueue")

  /// Checks out the given dependency into its intended working directory,
  /// cloning it first if need be.
  private func checkoutOrCloneDependency(
    _ dependency: Dependency,
    version: PinnedVersion,
    submodulesByPath: [String: Submodule]
  ) -> SignalProducer<Void, CarthageError> {
    let revision = version.commitish
    return cloneOrFetchDependency(dependency, commitish: revision)
      .flatMap(.merge) { repositoryURL -> SignalProducer<Void, CarthageError> in
        let workingDirectoryURL = self.directoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)

        /// The submodule for an already existing submodule at dependency project’s path
        /// or the submodule to be added at this path given the `--use-submodules` flag.
        let submodule: Submodule?

        if var foundSubmodule = submodulesByPath[dependency.relativePath] {
          foundSubmodule.url = dependency.gitURL(preferHTTPS: self.preferHTTPS)!
          foundSubmodule.sha = revision
          submodule = foundSubmodule
        } else if self.useSubmodules {
          submodule = Submodule(name: dependency.relativePath, path: dependency.relativePath, url: dependency.gitURL(preferHTTPS: self.preferHTTPS)!, sha: revision)
        } else {
          submodule = nil
        }

        let symlinkCheckoutPaths = self.symlinkCheckoutPaths(for: dependency, version: version, withRepository: repositoryURL, atRootDirectory: self.directoryURL)

        if let submodule = submodule {
          // In the presence of `submodule` for `dependency` — before symlinking, (not after) — add submodule and its submodules:
          // `dependency`, subdependencies that are submodules, and non-Carthage-housed submodules.
          return addSubmoduleToRepository(self.directoryURL, submodule, GitURL(repositoryURL.path))
            .startOnQueue(self.gitOperationQueue)
            .then(symlinkCheckoutPaths)
        } else {
          return checkoutRepositoryToDirectory(repositoryURL, workingDirectoryURL, revision: revision)
            // For checkouts of “ideally bare” repositories of `dependency`, we add its submodules by cloning ourselves, after symlinking.
            .then(symlinkCheckoutPaths)
            .then(
              submodulesInRepository(repositoryURL, revision: revision)
                .flatMap(.merge) {
                  cloneSubmoduleInWorkingDirectory($0, workingDirectoryURL)
                }
            )
        }
      }
      .on(started: {
        self._projectEventsObserver.send(value: .checkingOut(dependency, revision))
      })
  }

  private func buildOrderForResolvedCartfile(
    _ cartfile: ResolvedCartfile,
    dependenciesToInclude: [String]? = nil
  ) -> SignalProducer<BuildGraphNode, CarthageError> {
    // swiftlint:disable:next nesting
    typealias DependencyGraph = [Dependency: Set<Dependency>]

    // A resolved cartfile already has all the recursive dependencies. All we need to do is sort
    // out the relationships between them. Loading the cartfile will each will give us its
    // dependencies. Building a recursive lookup table with this information will let us sort
    // dependencies before the projects that depend on them.
    return SignalProducer<ResolvedDependency, CarthageError>(cartfile.dependencies.map(ResolvedDependency.init))
      .flatMap(.merge) { resolvedDependency -> SignalProducer<DependencyGraph, CarthageError> in
        self.dependencySet(for: resolvedDependency.dependency, version: resolvedDependency.version)
          .map { dependencies in
            [resolvedDependency.dependency: dependencies]
          }
      }
      .reduce(into: [:]) { (working: inout DependencyGraph, next: DependencyGraph) in
        for (key, value) in next {
          working.updateValue(value, forKey: key)
        }
      }
      .flatMap(.latest) { (graph: DependencyGraph) -> SignalProducer<BuildGraphNode, CarthageError> in
        let dependenciesToInclude = Set(graph.keys
          .filter { dependency in dependenciesToInclude?.contains(dependency.name) ?? false })

        guard let sortedDependencies = topologicalSort(graph, nodes: dependenciesToInclude) else { // swiftlint:disable:this single_line_guard
          return SignalProducer(error: .dependencyCycle(graph))
        }

        let sortedPinnedDependencies = cartfile.dependencies.keys
          .filter { dependency in sortedDependencies.contains(dependency) }
          .sorted { left, right in sortedDependencies.firstIndex(of: left)! < sortedDependencies.firstIndex(of: right)! }
          .map { ResolvedDependency(dependency:$0, version: cartfile.dependencies[$0]!) }
          .map { BuildGraphNode(resolvedDependency: $0, dependencies: graph[$0.dependency, default: Set()]) }

        return SignalProducer(sortedPinnedDependencies)
      }
  }

  /// Checks out the dependencies listed in the project's Cartfile.resolved,
  /// optionally they are limited by the given list of dependency names.
  public func checkoutResolvedDependencies(_ dependenciesToCheckout: [String]? = nil, buildOptions _: BuildOptions?) -> SignalProducer<Void, CarthageError> {
    /// Determine whether the repository currently holds any submodules (if
    /// it even is a repository).
    let submodulesSignal = submodulesInRepository(directoryURL)
      .reduce(into: [:]) { (submodulesByPath: inout [String: Submodule], submodule) in
        submodulesByPath[submodule.path] = submodule
      }

    return loadResolvedCartfile()
      .flatMap(.latest) { resolvedCartfile -> SignalProducer<([String]?, ResolvedCartfile), CarthageError> in
        guard let dependenciesToCheckout = dependenciesToCheckout else {
          return SignalProducer(value: (nil, resolvedCartfile))
        }

        return self
          .transitiveDependencies(dependenciesToCheckout, resolvedCartfile: resolvedCartfile)
          .map { (dependenciesToCheckout + $0, resolvedCartfile) }
      }
      .map { dependenciesToCheckout, resolvedCartfile -> [(Dependency, PinnedVersion)] in
        resolvedCartfile.dependencies
          .filter { dep, _ in dependenciesToCheckout?.contains(dep.name) ?? true }
      }
      .zip(with: submodulesSignal)
      .flatMap(.merge) { dependencies, submodulesByPath -> SignalProducer<Void, CarthageError> in
        SignalProducer<(Dependency, PinnedVersion), CarthageError>(dependencies)
          .flatMap(.concurrent(limit: 4)) { dependency, version -> SignalProducer<Void, CarthageError> in
            switch dependency {
              case .git, .gitHub:
                return self.checkoutOrCloneDependency(dependency, version: version, submodulesByPath: submodulesByPath)
              case .binary:
                return .empty
            }
          }
      }
      .then(SignalProducer<Void, CarthageError>.empty)
  }

  private func installBinariesForBinaryProject(
    binary: BinaryURL,
    pinnedVersion: PinnedVersion,
    projectName: String,
    toolchain: String?,
    preferXCFrameworks: Bool
  ) -> SignalProducer<Void, CarthageError> {
    return SignalProducer<SemanticVersion, ScannableError>(result: SemanticVersion.from(pinnedVersion))
      .mapError { CarthageError(scannableError: $0) }
      .combineLatest(with: downloadBinaryFrameworkDefinition(binary: binary))
      .flatMap(.concat) { semanticVersion, binaryProject -> SignalProducer<(SemanticVersion, URL), CarthageError> in
        guard let frameworkURLs = binaryProject.versions[pinnedVersion] else {
          return SignalProducer(error: CarthageError.requiredVersionNotFound(Dependency.binary(binary), VersionSpecifier.exactly(semanticVersion)))
        }

        let urlsAndVersions = binaryAssetFilter(prioritizing: frameworkURLs, preferXCFrameworks: preferXCFrameworks)
          .map { (semanticVersion, $0) }

        return SignalProducer(urlsAndVersions)
      }
      .flatMap(.concat) { semanticVersion, frameworkURL in
        self.downloadBinary(dependency: Dependency.binary(binary), version: semanticVersion, url: frameworkURL)
      }
      .flatMap(.concat) { zipFile in
        self.unarchiveAndCopyBinaryFrameworks(zipFile: zipFile, projectName: projectName, pinnedVersion: pinnedVersion, toolchain: toolchain)
          .on(failed: { _ in
            try? FileManager.default.removeItem(at: zipFile)
          })
      }
      .flatMap(.concat) { self.removeItem(at: $0) }
  }

  /// Downloads the binary only framework file. Sends the URL to each downloaded zip, after it has been moved to a
  /// less temporary location.
  private func downloadBinary(dependency: Dependency, version: SemanticVersion, url: URL) -> SignalProducer<URL, CarthageError> {
    let fileURL = downloadURLToCachedBinaryDependency(dependency, version, url)

    if FileManager.default.fileExists(atPath: fileURL.path) {
      return SignalProducer(value: fileURL)
    } else {
      let request = buildURLRequest(for: url, useNetrc: useNetrc)
      return URLSession.proxiedSession.reactive.download(with: request)
        .on(started: {
          self._projectEventsObserver.send(value: .downloadingBinaries(dependency, version.description))
        })
        .mapError { CarthageError.readFailed(url, $0 as NSError) }
        .flatMap(.concat) { downloadURL, _ in cacheDownloadedBinary(downloadURL, toURL: fileURL) }
    }
  }

  /// Creates symlink between the dependency checkouts and the root checkouts
  private func symlinkCheckoutPaths(
    for dependency: Dependency,
    version: PinnedVersion,
    withRepository repositoryURL: URL,
    atRootDirectory rootDirectoryURL: URL
  ) -> SignalProducer<Void, CarthageError> {
    let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
    let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()
    let dependencyCheckoutsURL = dependencyURL.appendingPathComponent(Constants.checkoutsFolderPath, isDirectory: true).resolvingSymlinksInPath()
    let fileManager = FileManager.default

    return dependencySet(for: dependency, version: version)
      // file system objects which might conflict with symlinks
      .zip(with: list(treeish: version.commitish, atPath: Constants.checkoutsFolderPath, inRepository: repositoryURL)
        .map { (path: String) in (path as NSString).lastPathComponent }
        .collect()
      )
      .attemptMap { (dependencies: Set<Dependency>, components: [String]) -> Result<Void, CarthageError> in
        let names = dependencies
          .filter { dependency in
            // Filter out dependencies with names matching (case-insensitively) file system objects from git in `CarthageProjectCheckoutsPath`.
            // Edge case warning on file system case-sensitivity. If a differently-cased file system object exists in git
            // and is stored on a case-sensitive file system (like the Sierra preview of APFS), we currently preempt
            // the non-conflicting symlink. Probably, nobody actually desires or needs the opposite behavior.
            !components.contains {
              dependency.name.caseInsensitiveCompare($0) == .orderedSame
            }
          }
          .map { $0.name }

        // If no `CarthageProjectCheckoutsPath`-housed symlinks are needed,
        // return early after potentially adding submodules
        // (which could be outside `CarthageProjectCheckoutsPath`).
        if names.isEmpty { return .success(()) } // swiftlint:disable:this single_line_return

        do {
          try fileManager.createDirectory(at: dependencyCheckoutsURL, withIntermediateDirectories: true)
        } catch let error as NSError {
          if !(error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError) {
            return .failure(.writeFailed(dependencyCheckoutsURL, error))
          }
        }

        for name in names {
          let dependencyCheckoutURL = dependencyCheckoutsURL.appendingPathComponent(name)
          let subdirectoryPath = (Constants.checkoutsFolderPath as NSString).appendingPathComponent(name)
          let linkDestinationPath = relativeLinkDestination(for: dependency, subdirectory: subdirectoryPath)

          let dependencyCheckoutURLResource = try? dependencyCheckoutURL.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isDirectoryKey
          ])

          if dependencyCheckoutURLResource?.isSymbolicLink == true {
            _ = dependencyCheckoutURL.path.withCString(Darwin.unlink)
          } else if dependencyCheckoutURLResource?.isDirectory == true {
            // older version of utica wrote this directory?
            // user wrote this directory, unaware of the precedent not to circumvent carthage’s management?
            // directory exists as the result of rogue process or gamma ray?

            // swiftlint:disable:next todo
            // TODO: explore possibility of messaging user, informing that deleting said directory will result
            // in symlink creation with utica versions greater than 0.20.0, maybe with more broad advice on
            // “from scratch” reproducability.
            continue
          }

          if let error = Result(at: dependencyCheckoutURL, attempt: {
            try fileManager.createSymbolicLink(atPath: $0.path, withDestinationPath: linkDestinationPath)
          }).error {
            return .failure(error)
          }
        }

        return .success(())
      }
  }

  struct ConcurrentBuildState {
    typealias Observer = (Signal<ResolvedDependency, CarthageError>.Observer, Lifetime)
    var observer: Observer? {
      didSet {
        if observer != nil {
          sendNextChunk()
        }
      }
    }
    private var builtDependencies: Set<Dependency>
    private var dependencies: [BuildGraphNode]

    init(dependencies: [BuildGraphNode], builtDependencies: Set<Dependency>) {
      self.dependencies = dependencies
      self.builtDependencies = builtDependencies
      self.observer = nil
    }

    mutating func markAsBuilt(dependency: Dependency) {
      builtDependencies.insert(dependency)
      sendNextChunk()
    }

    private mutating func sendNextChunk() {
      guard let (observer, lifetime) = observer else {
        return
      }

      guard !lifetime.hasEnded else {
        self.observer = nil
        return
      }

      let pivot = dependencies.partition { $0.dependencies.isSubset(of: builtDependencies) }
      dependencies[pivot...]
        .forEach {
          if !lifetime.hasEnded {
            observer.send(value: $0.resolvedDependency)
          }
        }
      dependencies.removeSubrange(pivot...)
      if dependencies.isEmpty {
        if !lifetime.hasEnded {
          observer.sendCompleted()
        }
        self.observer = nil
      }
    }
  }

  private func concurrentBuildDependencies(
    _ dependenciesToBuild: [BuildGraphNode],
    prebuiltDependencies: Set<Dependency>,
    options: BuildOptions,
    sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) }
  ) -> BuildSchemeProducer {
    let numberOfJobs = options.concurrentJobsCount > 0 ? UInt(options.concurrentJobsCount) : UInt(ProcessInfo.processInfo.processorCount)
    let state = Atomic(
      ConcurrentBuildState(dependencies: dependenciesToBuild, builtDependencies: prebuiltDependencies)
    )
    return SignalProducer<ResolvedDependency, CarthageError> { observer, lifetime in
      state.modify { $0.observer = (observer, lifetime) }
    }
    .observe(on: QueueScheduler(qos: .default, name: "org.utica.UticaKit.Project.concurrentBuildDependencies"))
    .flatMap(.concurrent(limit: numberOfJobs)) { resolvedDependency -> BuildSchemeProducer in
      self.symlinkAndBuild(
        dependency: resolvedDependency.dependency,
        version: resolvedDependency.version,
        options: options,
        sdkFilter: sdkFilter
      )
      .on(completed: { state.modify { $0.markAsBuilt(dependency: resolvedDependency.dependency) } })
    }
  }

  /// Attempts to build each Carthage dependency that has been checked out,
  /// optionally they are limited by the given list of dependency names.
  /// Cached dependencies whose dependency trees are also cached will not
  /// be rebuilt unless otherwise specified via build options.
  ///
  /// Returns a producer-of-producers representing each scheme being built.
  public func buildCheckedOutDependenciesWithOptions(
    _ options: BuildOptions,
    dependenciesToBuild: [String]? = nil,
    sdkFilter: @escaping SDKFilterCallback = { sdks, _, _, _ in .success(sdks) }
  ) -> BuildSchemeProducer {
    loadResolvedCartfile()
      .flatMap(.race) { resolvedCartfile -> SignalProducer<BuildGraphNode, CarthageError> in
        self.buildOrderForResolvedCartfile(resolvedCartfile, dependenciesToInclude: dependenciesToBuild)
      }
      .flatMap(.concat) { node -> SignalProducer<(BuildGraphNode, Bool?), CarthageError> in
        SignalProducer.combineLatest(
          SignalProducer(value: node),
          versionFileMatches(node.dependency, version: node.version, platforms: options.platforms, rootDirectoryURL: self.directoryURL, toolchain: options.toolchain)
        )
      }
      .collect()
      .map {
        var includedDependencies = [BuildGraphNode]()
        var skippedDependencies = Set<Dependency>()
        for (nextNode, matches) in $0 {
          if self.filterDependenciesToBuild(
            nextNode,
            includedDependencies: includedDependencies,
            versionFileMatches: matches,
            cacheBuilds: options.cacheBuilds
          ) {
            includedDependencies.append(nextNode)
          } else {
            skippedDependencies.insert(nextNode.dependency)
          }
        }
        return (includedDependencies, skippedDependencies)
      }
      .flatMap(.merge) { (graph: [BuildGraphNode], skippedDependencies: Set<Dependency>) -> BuildSchemeProducer in
        self.installBinaryDependencies(graph.map(\.resolvedDependency), options: options)
          .flatMap(.race) { installedDependencies -> BuildSchemeProducer in
            // Filters out dependencies that we've downloaded binaries for
            // but preserves the build order
            let prebuiltDependencies = skippedDependencies.union(installedDependencies.map(\.dependency))
            return self.concurrentBuildDependencies(
              graph.filter { !installedDependencies.contains($0.resolvedDependency) },
              prebuiltDependencies: prebuiltDependencies,
              options: options,
              sdkFilter: sdkFilter
            )
          }
      }
  }

  private func filterDependenciesToBuild(
    _ nextDependency: BuildGraphNode,
    includedDependencies: [BuildGraphNode],
    versionFileMatches: Bool?,
    cacheBuilds: Bool
  ) -> Bool {
    let projectsToBeBuilt = Set(includedDependencies.map(\.dependency))

    guard cacheBuilds, nextDependency.dependencies.isDisjoint(with: projectsToBeBuilt) else {
      return true
    }

    guard let versionFileMatches = versionFileMatches else {
      self._projectEventsObserver.send(value: .buildingUncached(nextDependency.dependency))
      return true
    }

    if versionFileMatches {
      self._projectEventsObserver.send(value: .skippedBuildingCached(nextDependency.dependency))
      return false
    } else {
      self._projectEventsObserver.send(value: .rebuildingCached(nextDependency.dependency))
      return true
    }
  }

  private func installBinaryDependencies(
    _ dependencies: [ResolvedDependency],
    options: BuildOptions
  ) -> SignalProducer<[ResolvedDependency], CarthageError> {
    SignalProducer(dependencies)
      .flatMap(.concurrent(limit: 4)) { resolvedDependency -> SignalProducer<ResolvedDependency, CarthageError> in
        switch resolvedDependency.dependency {
          case .git, .gitHub:
            guard options.useBinaries else {
              return .empty
            }
            return self.installBinaries(
              for: resolvedDependency.dependency,
              pinnedVersion: resolvedDependency.version,
              preferXCFrameworks: options.useXCFrameworks,
              toolchain: options.toolchain
            )
            .compactMap { installed -> ResolvedDependency? in
              installed ? resolvedDependency : nil
            }
          case let .binary(binary):
            return self.installBinariesForBinaryProject(
              binary: binary,
              pinnedVersion: resolvedDependency.version,
              projectName: resolvedDependency.dependency.name,
              toolchain: options.toolchain,
              preferXCFrameworks: options.useXCFrameworks
            )
            .then(SignalProducer(value: resolvedDependency))
        }
      }
      .flatMap(.merge) { resolvedDependency -> SignalProducer<ResolvedDependency, CarthageError> in
        // Symlink the build folder of binary downloads for consistency with regular checkouts
        // (even though it's not necessary since binary downloads aren't built by Carthage)
        self.symlinkBuildPathIfNeeded(for: resolvedDependency.dependency, version: resolvedDependency.version)
          .then(SignalProducer(value: resolvedDependency))
      }
      .collect()
  }

  private func symlinkAndBuild(
    dependency: Dependency,
    version: PinnedVersion,
    options: BuildOptions,
    sdkFilter: @escaping SDKFilterCallback
  ) -> BuildSchemeProducer {
    let dependencyPath = self.directoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true).path
    if !FileManager.default.fileExists(atPath: dependencyPath) {
      return .empty
    }

    var options = options
    let baseURL = options.derivedDataPath.flatMap(URL.init(string:)) ?? Constants.Dependency.derivedDataURL
    let derivedDataPerXcode = baseURL.appendingPathComponent(self.xcodeVersionDirectory, isDirectory: true)
    let derivedDataPerDependency = derivedDataPerXcode.appendingPathComponent(dependency.name, isDirectory: true)
    let derivedDataVersioned = derivedDataPerDependency.appendingPathComponent(version.commitish, isDirectory: true)
    options.derivedDataPath = derivedDataVersioned.resolvingSymlinksInPath().path

    return self.symlinkBuildPathIfNeeded(for: dependency, version: version)
      .then(build(dependency: dependency, version: version, self.directoryURL, withOptions: options, sdkFilter: sdkFilter))
      .flatMapError { error -> BuildSchemeProducer in
        switch error {
          case .noSharedFrameworkSchemes:
            // Log that building the dependency is being skipped,
            // not to error out with `.noSharedFrameworkSchemes`
            // to continue building other dependencies.
            self._projectEventsObserver.send(value: .skippedBuilding(dependency, error.description))

            if options.cacheBuilds {
              // Create a version file for a dependency with no shared schemes
              // so that its cache is not always considered invalid.
              return createVersionFileForCommitish(
                version.commitish,
                dependencyName: dependency.name,
                platforms: options.platforms,
                buildProducts: [],
                rootDirectoryURL: self.directoryURL
              )
              .then(BuildSchemeProducer.empty)
            }
            return .empty

          default:
            return SignalProducer(error: error)
        }
      }
  }

  private func symlinkBuildPathIfNeeded(for dependency: Dependency, version: PinnedVersion) -> SignalProducer<Void, CarthageError> {
    return dependencySet(for: dependency, version: version)
      .flatMap(.merge) { dependencies -> SignalProducer<Void, CarthageError> in
        // Don't symlink the build folder if the dependency doesn't have
        // any Carthage dependencies
        if dependencies.isEmpty {
          return .empty
        }
        return symlinkBuildPath(for: dependency, rootDirectoryURL: self.directoryURL)
      }
  }

  /// Determines whether the requirements specified in this project's Cartfile.resolved
  /// are compatible with the versions specified in the Cartfile for each of those projects.
  ///
  /// Either emits a value to indicate success or an error.
  public func validate(resolvedCartfile: ResolvedCartfile) -> SignalProducer<Void, CarthageError> {
    return SignalProducer(value: resolvedCartfile)
      .flatMap(.concat) { (resolved: ResolvedCartfile) -> SignalProducer<([Dependency: PinnedVersion], CompatibilityInfo.Requirements), CarthageError> in
        let requirements = self.requirementsByDependency(resolvedCartfile: resolved, tryCheckoutDirectory: true)
        return SignalProducer.zip(SignalProducer(value: resolved.dependencies), requirements)
      }
      .flatMap(.concat) { (info: ([Dependency: PinnedVersion], CompatibilityInfo.Requirements)) -> SignalProducer<[CompatibilityInfo], CarthageError> in
        let (dependencies, requirements) = info
        return .init(result: CompatibilityInfo.incompatibilities(for: dependencies, requirements: requirements))
      }
      .flatMap(.concat) { incompatibilities -> SignalProducer<Void, CarthageError> in
        incompatibilities.isEmpty ? .init(value: ()) : .init(error: .invalidResolvedCartfile(incompatibilities))
      }
  }
}

/// Creates symlink between the dependency build folder and the root build folder
///
/// Returns a signal indicating success
private func symlinkBuildPath(for dependency: Dependency, rootDirectoryURL: URL) -> SignalProducer<Void, CarthageError> {
  return SignalProducer { () -> Result<Void, CarthageError> in
    let rootBinariesURL = rootDirectoryURL.appendingPathComponent(Constants.binariesFolderPath, isDirectory: true).resolvingSymlinksInPath()
    let rawDependencyURL = rootDirectoryURL.appendingPathComponent(dependency.relativePath, isDirectory: true)
    let dependencyURL = rawDependencyURL.resolvingSymlinksInPath()
    let fileManager = FileManager.default

    // Link this dependency's Carthage/Build folder to that of the root
    // project, so it can see all products built already, and so we can
    // automatically drop this dependency's product in the right place.
    let dependencyBinariesURL = dependencyURL.appendingPathComponent(Constants.binariesFolderPath, isDirectory: true)

    let createDirectory = { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) }
    return Result(at: rootBinariesURL, attempt: createDirectory)
      .flatMap { _ in
        Result(at: dependencyBinariesURL, attempt: fileManager.removeItem(at:))
          .recover(with: Result(at: dependencyBinariesURL.deletingLastPathComponent(), attempt: createDirectory))
      }
      .flatMap { _ in
        Result(at: rawDependencyURL, carthageError: CarthageError.readFailed, attempt: {
          try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
        })
          .flatMap { isSymlink in
            Result(at: dependencyBinariesURL, attempt: {
              if isSymlink == true {
                return try fileManager.createSymbolicLink(at: $0, withDestinationURL: rootBinariesURL)
              } else {
                let linkDestinationPath = relativeLinkDestination(for: dependency, subdirectory: Constants.binariesFolderPath)
                return try fileManager.createSymbolicLink(atPath: $0.path, withDestinationPath: linkDestinationPath)
              }
            })
          }
      }
  }
}

/// Constructs a file URL to where the binary corresponding to the given
/// arguments should live.
private func fileURLToCachedBinary(_ dependency: Dependency, _ release: Release, _ asset: Release.Asset) -> URL {
  // ~/Library/Caches/org.utica.UticaKit/binaries/ReactiveCocoa/v2.3.1/1234-ReactiveCocoa.framework.zip
  return Constants.Dependency.assetsURL.appendingPathComponent("\(dependency.name)/\(release.tag)/\(asset.id)-\(asset.name)", isDirectory: false)
}

/// Constructs a file URL to where the binary only framework download should be cached
private func downloadURLToCachedBinaryDependency(_ dependency: Dependency, _ semanticVersion: SemanticVersion, _ url: URL) -> URL {
  let urlBytes = url.absoluteString.utf8CString
  var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
  _ = digest.withUnsafeMutableBytes { buffer in
    urlBytes.withUnsafeBytes { data in
      CC_SHA256(data.baseAddress!, CC_LONG(urlBytes.count), buffer)
    }
  }
  let hexDigest = digest.map { String(format: "%02hhx", $0) }.joined()
  let fileName = url.deletingPathExtension().lastPathComponent
  let fileExtension = url.pathExtension

  // ~/Library/Caches/org.utica.UticaKit/binaries/MyBinaryProjectFramework/2.3.1/MyBinaryProject.framework-578d2a1e3a62983f70dfd8d0b04531b77615cc381edd603813657372d40a8fa1.zip
  return Constants.Dependency.assetsURL
    .appendingPathComponent("\(dependency.name)/\(semanticVersion)/\(fileName)-\(hexDigest).\(fileExtension)")
}

/// Caches the downloaded binary at the given URL, moving it to the other URL
/// given.
///
/// Sends the final file URL upon .success.
private func cacheDownloadedBinary(_ downloadURL: URL, toURL cachedURL: URL) -> SignalProducer<URL, CarthageError> {
  return SignalProducer(value: cachedURL)
    .attempt { fileURL in
      Result(at: fileURL.deletingLastPathComponent(), attempt: {
        try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
      })
    }
    .attempt { newDownloadURL in
      // Tries `rename()` system call at first.
      let result = downloadURL.withUnsafeFileSystemRepresentation { old in
        newDownloadURL.withUnsafeFileSystemRepresentation { new in
          rename(old!, new!)
        }
      }
      if result == 0 {
        return .success(())
      }

      if errno != EXDEV {
        return .failure(.taskError(.posixError(errno)))
      }

      // If the “Cross-device link” error occurred, then falls back to
      // `FileManager.moveItem(at:to:)`.
      //
      // See https://github.com/Carthage/Carthage/issues/706 and
      // https://github.com/Carthage/Carthage/issues/711.
      return Result(at: newDownloadURL, attempt: {
        try FileManager.default.moveItem(at: downloadURL, to: $0)
      })
    }
}

/// Sends the URL to each file found in the given directory conforming to the
/// given type identifier. If no type identifier is provided, all files are sent.
private func filesInDirectory(_ directoryURL: URL, _ typeIdentifier: String? = nil) -> SignalProducer<URL, CarthageError> {
  let producer = FileManager.default.reactive
    .enumerator(at: directoryURL, includingPropertiesForKeys: [.typeIdentifierKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], catchErrors: true)
    .map { _, url in url }
  if let typeIdentifier = typeIdentifier {
    return producer
      .filter { url in
        url.typeIdentifier
          .analysis(ifSuccess: { identifier in
            UTTypeConformsTo(identifier as CFString, typeIdentifier as CFString)
          }, ifFailure: { _ in false })
      }
  } else {
    return producer
  }
}

/// Sends the platform specified in the given Info.plist.
func platformForFramework(_ frameworkURL: URL) -> SignalProducer<SDK, CarthageError> {
  return SignalProducer(value: frameworkURL)
    // Neither DTPlatformName nor CFBundleSupportedPlatforms can not be used
    // because Xcode 6 and below do not include either in macOS frameworks.
    .attemptMap { url -> Result<String, CarthageError> in
      let bundle = Bundle(url: url)

      func readFailed(_ message: String) -> CarthageError {
        let error = Result<Void, NSError>.error(message)
        return .readFailed(frameworkURL, error)
      }

      func sdkNameFromExecutable() -> String? {
        guard let executableURL = bundle?.executableURL else {
          return nil
        }

        let task = Task("/usr/bin/xcrun", arguments: ["otool", "-lv", executableURL.path])

        let sdkName: String? = task.launch(standardInput: nil)
          .ignoreTaskData()
          .map { String(data: $0, encoding: .utf8) ?? "" }
          .filter { !$0.isEmpty }
          .flatMap(.merge) { (output: String) -> SignalProducer<String, Never> in
            output.linesProducer
          }
          .filter { $0.contains("LC_VERSION") }
          .take(last: 1)
          .map { lcVersionLine -> String? in
            let sdkString = lcVersionLine.split(separator: "_")
              .last
              .flatMap(String.init)
              .flatMap { $0.lowercased() }

            return sdkString
          }
          .skipNil()
          .single()?
          .value

        return sdkName
      }

      // Try to read what platfrom this binary is for. Attempt in order:
      // 1. Read `DTSDKName` from Info.plist.
      //    Some users are reporting that static frameworks don't have this key in the .plist,
      //    so we fall back and check the binary of the executable itself.
      // 2. Read the LC_VERSION_<PLATFORM> from the framework's binary executable file

      if let sdkNameFromBundle = bundle?.object(forInfoDictionaryKey: "DTSDKName") as? String {
        return .success(sdkNameFromBundle)
      } else if let sdkNameFromExecutable = sdkNameFromExecutable() {
        return .success(sdkNameFromExecutable)
      } else {
        return .failure(readFailed("could not determine platform neither from DTSDKName key in plist nor from the framework's executable"))
      }
    }
    // Thus, the SDK name must be trimmed to match the platform name, e.g.
    // macosx10.10 -> macosx
    .map { sdkName in sdkName.trimmingCharacters(in: CharacterSet.letters.inverted) }
    .map { SDK(name: $0, simulatorHeuristic: "") }
}

/// Sends the URL to each framework bundle found in the given directory.
internal func frameworksInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
  return filesInDirectory(directoryURL, kUTTypeFramework as String)
    .concat(filesInDirectory(directoryURL, "com.apple.xcframework"))
    .filter { !$0.pathComponents.contains("__MACOSX") }
    .filter { url in
      // Skip nested frameworks
      let frameworksInURL = url.pathComponents.filter { pathComponent in
        ["framework", "xcframework"].contains((pathComponent as NSString).pathExtension)
      }
      return frameworksInURL.count == 1
    }.filter { url in
      // For reasons of speed and the fact that CLI-output structures can change,
      // first try the safer method of reading the ‘Info.plist’ from the Framework’s bundle.
      let bundle = Bundle(url: url)
      let packageType: PackageType? = bundle?.packageType

      switch packageType {
        case .xcframework?, .framework?, .bundle?:
          return true
        default:
          // In case no Info.plist exists check the Mach-O fileType
          guard let executableURL = bundle?.executableURL else {
            return false
          }

          return MachHeader.headers(forMachOFileAtUrl: executableURL)
            .filter { MachHeader.carthageSupportedFileTypes.contains($0.fileType) }
            .reduce(into: Set<UInt32>()) { $0.insert($1.fileType) }
            .map { $0.count == 1 }
            .single()?
            .value ?? false
      }
    }
}

/// Sends the URL to each dSYM found in the given directory
internal func dSYMsInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
  return filesInDirectory(directoryURL, "com.apple.xcode.dsym")
}

/// Sends the URL of the dSYM for which at least one of the UUIDs are common with
/// those of the given framework, or errors if there was an error parsing a dSYM
/// contained within the directory.
private func dSYMForFramework(_ frameworkURL: URL, inDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
  return UUIDsForFramework(frameworkURL)
    .flatMap(.concat) { (frameworkUUIDs: Set<UUID>) in
      dSYMsInDirectory(directoryURL)
        .flatMap(.merge) { dSYMURL in
          UUIDsForDSYM(dSYMURL)
            .filter { (dSYMUUIDs: Set<UUID>) in
              !dSYMUUIDs.isDisjoint(with: frameworkUUIDs)
            }
            .map { _ in dSYMURL }
        }
    }
    .take(first: 1)
}

/// Sends the URL to each bcsymbolmap found in the given directory.
internal func BCSymbolMapsInDirectory(_ directoryURL: URL) -> SignalProducer<URL, CarthageError> {
  return filesInDirectory(directoryURL)
    .filter { url in url.pathExtension == "bcsymbolmap" }
}

/// Sends the URLs of the bcsymbolmap files that match the given framework and are
/// located somewhere within the given directory.
private func BCSymbolMapsForFramework(_ frameworkURL: URL, inDirectoryURL directoryURL: URL) -> SignalProducer<URL, CarthageError> {
  return UUIDsForFramework(frameworkURL)
    .flatMap(.merge) { uuids -> SignalProducer<URL, CarthageError> in
      if uuids.isEmpty {
        return .empty
      }
      func filterUUIDs(_ signal: Signal<URL, CarthageError>) -> Signal<URL, CarthageError> {
        var remainingUUIDs = uuids
        let count = remainingUUIDs.count
        return signal
          .filter { fileURL in
            let basename = fileURL.deletingPathExtension().lastPathComponent
            if let fileUUID = UUID(uuidString: basename) {
              return remainingUUIDs.remove(fileUUID) != nil
            } else {
              return false
            }
          }
          .take(first: count)
      }
      return BCSymbolMapsInDirectory(directoryURL)
        .lift(filterUUIDs)
    }
}

/// Returns the file URL at which the given project's repository will be
/// located.
private func repositoryFileURL(for dependency: Dependency, baseURL: URL = Constants.Dependency.repositoriesURL) -> URL {
  return baseURL.appendingPathComponent(dependency.name, isDirectory: true)
}

/// Returns the string representing a relative path from a dependency back to the root
internal func relativeLinkDestination(for dependency: Dependency, subdirectory: String) -> String {
  let dependencySubdirectoryPath = (dependency.relativePath as NSString).appendingPathComponent(subdirectory)
  let componentsForGettingTheHellOutOfThisRelativePath = Array(repeating: "..", count: (dependencySubdirectoryPath as NSString).pathComponents.count - 1)

  // Directs a link from, e.g., /Carthage/Checkouts/ReactiveCocoa/Carthage/Build to /Carthage/Build
  let linkDestinationPath = componentsForGettingTheHellOutOfThisRelativePath.reduce(subdirectory) { trailingPath, pathComponent in
    (pathComponent as NSString).appendingPathComponent(trailingPath)
  }

  return linkDestinationPath
}

/// Clones the given project to the given destination URL (defaults to the global
/// repositories folder), or fetches inside it if it has already been cloned.
/// Optionally takes a commitish to check for prior to fetching.
///
/// Returns a signal which will send the operation type once started, and
/// the URL to where the repository's folder will exist on disk, then complete
/// when the operation completes.
public func cloneOrFetch(
  dependency: Dependency,
  preferHTTPS: Bool,
  destinationURL: URL = Constants.Dependency.repositoriesURL,
  commitish: String? = nil
) -> SignalProducer<(ProjectEvent?, URL), CarthageError> {
  let fileManager = FileManager.default
  let repositoryURL = repositoryFileURL(for: dependency, baseURL: destinationURL)

  return SignalProducer {
    Result(at: destinationURL, attempt: {
      try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
      return dependency.gitURL(preferHTTPS: preferHTTPS)!
    })
  }
  .flatMap(.merge) { (remoteURL: GitURL) -> SignalProducer<(ProjectEvent?, URL), CarthageError> in
    isGitRepository(repositoryURL)
      .flatMap(.merge) { isRepository -> SignalProducer<(ProjectEvent?, URL), CarthageError> in
        if isRepository {
          let fetchProducer: () -> SignalProducer<(ProjectEvent?, URL), CarthageError> = {
            guard FetchCache.needsFetch(forURL: remoteURL) else {
              return SignalProducer(value: (nil, repositoryURL))
            }

            return SignalProducer(value: (.fetching(dependency), repositoryURL))
              .concat(
                fetchRepository(repositoryURL, remoteURL: remoteURL, refspec: "+refs/heads/*:refs/heads/*")
                  .then(SignalProducer<(ProjectEvent?, URL), CarthageError>.empty)
              )
          }

          // If we've already cloned the repo, check for the revision, possibly skipping an unnecessary fetch
          if let commitish = commitish {
            return SignalProducer.zip(
              branchExistsInRepository(repositoryURL, pattern: commitish),
              commitExistsInRepository(repositoryURL, revision: commitish)
            )
            .flatMap(.concat) { branchExists, commitExists -> SignalProducer<(ProjectEvent?, URL), CarthageError> in
              // If the given commitish is a branch, we should fetch.
              if branchExists || !commitExists {
                return fetchProducer()
              } else {
                return SignalProducer(value: (nil, repositoryURL))
              }
            }
          } else {
            return fetchProducer()
          }
        } else {
          // Either the directory didn't exist or it did but wasn't a git repository
          // (Could happen if the process is killed during a previous directory creation)
          // So we remove it, then clone
          _ = try? fileManager.removeItem(at: repositoryURL)
          return SignalProducer(value: (.cloning(dependency), repositoryURL))
            .concat(
              cloneRepository(remoteURL, repositoryURL)
                .then(SignalProducer<(ProjectEvent?, URL), CarthageError>.empty)
            )
        }
      }
  }
}

private func binaryAssetPrioritization(forName assetName: String) -> (keyName: String, priority: UInt8) {
  let priorities: KeyValuePairs = [".xcframework": 10 as UInt8, ".XCFramework": 10, ".XCframework": 10, ".framework": 40]

  for (pathExtension, priority) in priorities {
    var (potentialPatternRange, keyName) = (assetName.range(of: pathExtension), assetName)
    guard let patternRange = potentialPatternRange else { continue }
    keyName.removeSubrange(patternRange)
    return (keyName, priority)
  }

  // If we can't tell whether this is a framework or an xcframework, return it with a low priority.
  return (assetName, 70)
}

/**
 Given a list of known assets for a release, parses asset names to identify XCFramework assets, and returns which assets should be downloaded.

 For example:
 ```
 >>> binaryAssetFilter(
 		prioritizing: [Foo.xcframework.zip, Foo.framework.zip, Bar.framework.zip],
 		preferXCFrameworks: true
 	)
 [Foo.xcframework.zip, Bar.framework.zip]
 ```
 */
private func binaryAssetFilter<A: AssetNameConvertible>(prioritizing assets: [A], preferXCFrameworks: Bool) -> [A] {
  let bestPriorityAssetsByKey = assets.reduce(into: [:] as [String: [A: UInt8]]) { assetNames, asset in
    if asset.name.lowercased().contains(".xcframework"), !preferXCFrameworks {
      // Skip assets that look like xcframework when --use-xcframeworks is not passed.
      return
    }
    let (key, priority) = binaryAssetPrioritization(forName: asset.name)
    let assetPriorities = assetNames[key, default: [:]].merging([asset: priority], uniquingKeysWith: min)
    let bestPriority = assetPriorities.values.min()!
    assetNames[key] = assetPriorities.filter { $1 == bestPriority }
  }
  return bestPriorityAssetsByKey.values.flatMap { $0.keys }
}

private protocol AssetNameConvertible: Hashable {
  var name: String { get }
}

extension URL: AssetNameConvertible {
  var name: String { return lastPathComponent }
}

extension Release.Asset: AssetNameConvertible {}
