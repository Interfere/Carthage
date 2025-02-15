import Commandant
import Curry
import Foundation
import ReactiveSwift
import ReactiveTask
import Result
import UticaKit
import XCDBLD

extension BuildOptions: OptionsProtocol {
  public static func evaluate(_ mode: CommandMode) -> Result<BuildOptions, CommandantError<CarthageError>> {
    return evaluate(mode, addendum: "")
  }

  public static func evaluate(_ mode: CommandMode, addendum: String) -> Result<BuildOptions, CommandantError<CarthageError>> {
    var platformUsage = "the platforms to build for (one of 'all', 'macOS', 'iOS', 'watchOS', 'tvOS', or comma-separated values of the formers except for 'all')"
    platformUsage += addendum

    return curry(BuildOptions.init)
      <*> mode <| Option(key: "configuration", defaultValue: "Release", usage: "the Xcode configuration to build" + addendum)
      <*> (mode <| Option<BuildPlatform>(key: "platform", defaultValue: .all, usage: platformUsage))
      .map { if case let .setDisjointWithFlaggedAll(set) = $0 { return set } else { return nil } }
      <*> mode <| Option<String?>(key: "toolchain", defaultValue: nil, usage: "the toolchain to build with")
      <*> mode <| Option<String?>(key: "derived-data", defaultValue: nil, usage: "path to the custom derived data folder")
      <*> mode <| Option(key: "cache-builds", defaultValue: false, usage: "use cached builds when possible")
      <*> mode <| Option(key: "use-binaries", defaultValue: true, usage: "don't use downloaded binaries when possible")
      <*> mode <| Option(key: "use-xcframeworks", defaultValue: false, usage: "create xcframework bundles instead of one framework per platform (requires Xcode 12+)")
      <*> mode <| Option<String?>(key: "valid-simulator-archs", defaultValue: nil, usage: "explicitly list architectures valid for simulator")
      <*> mode <| Option<Int>(key: "jobs", defaultValue: 0, usage: "max number of concurrent xcodebuild tasks. Default: number of cores")
  }
}

/// Type that encapsulates the configuration and evaluation of the `build` subcommand.
public struct BuildCommand: CommandProtocol {
  public struct Options: OptionsProtocol {
    public let buildOptions: BuildOptions
    public let skipCurrent: Bool
    public let colorOptions: ColorOptions
    public let isVerbose: Bool
    public let directoryPath: String
    public let logPath: String?
    public let archive: Bool
    public let useNetrc: Bool
    public let dependenciesToBuild: [String]?

    /// If `archive` is true, this will be a producer that will archive
    /// the project after the build.
    ///
    /// Otherwise, this producer will be empty.
    public var archiveProducer: SignalProducer<Void, CarthageError> {
      if archive {
        let options = ArchiveCommand.Options(outputPath: nil, directoryPath: directoryPath, colorOptions: colorOptions, frameworkNames: [])
        return ArchiveCommand().archiveWithOptions(options)
      } else {
        return .empty
      }
    }

    public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
      let netrcOption = Option(
        key: "use-netrc",
        defaultValue: false,
        usage: "use authentication credentials from ~/.netrc file when downloading binary only frameworks"
      )

      return curry(Options.init)
        <*> BuildOptions.evaluate(mode)
        <*> mode <| Option(key: "skip-current", defaultValue: true, usage: "don't skip building the Carthage project (in addition to its dependencies)")
        <*> ColorOptions.evaluate(mode)
        <*> mode <| Option(key: "verbose", defaultValue: false, usage: "print xcodebuild output inline")
        <*> mode <| Option(key: "project-directory", defaultValue: FileManager.default.currentDirectoryPath, usage: "the directory containing the Carthage project")
        <*> mode <| Option(key: "log-path", defaultValue: nil, usage: "path to the xcode build output. A temporary file is used by default")
        <*> mode <| Option(key: "archive", defaultValue: false, usage: "archive built frameworks from the current project (implies --no-skip-current)")
        <*> mode <| netrcOption
        <*> (mode <| Argument(defaultValue: [], usage: "the dependency names to build", usageParameter: "dependency names")).map { $0.isEmpty ? nil : $0 }
    }
  }

  public let verb = "build"
  public let function = "Build the project's dependencies"

  public func run(_ options: Options) -> Result<Void, CarthageError> {
    return buildWithOptions(options)
      .then(options.archiveProducer)
      .waitOnCommand()
  }

  /// Builds a project with the given options.
  public func buildWithOptions(_ options: Options) -> SignalProducer<Void, CarthageError> {
    return openLoggingHandle(options)
      .flatMap(.merge) { stdoutHandle, temporaryURL -> SignalProducer<Void, CarthageError> in
        let directoryURL = URL(fileURLWithPath: options.directoryPath, isDirectory: true)

        let buildProgress = self.buildProjectInDirectoryURL(directoryURL, options: options)

        let stderrHandle = options.isVerbose ? FileHandle.standardError : stdoutHandle

        let formatting = options.colorOptions.formatting

        return buildProgress
          .mapError { error -> CarthageError in
            if case let .buildFailed(taskError, _) = error {
              return .buildFailed(taskError, log: temporaryURL)
            } else {
              return error
            }
          }
          .on(
            started: {
              if let path = temporaryURL?.path {
                utica.println(formatting.bullets + "xcodebuild output can be found in " + formatting.path(path))
              }
            },
            value: { taskEvent in
              switch taskEvent {
                case let .launch(task):
                  stdoutHandle.write(task.description.data(using: .utf8)!)

                case let .standardOutput(data):
                  stdoutHandle.write(data)

                case let .standardError(data):
                  stderrHandle.write(data)

                case let .success((project, scheme)):
                  utica.println(formatting.bullets + "Building scheme " + formatting.quote(scheme.name) + " in " + formatting.projectName(project.description))
              }
            }
          )
          .then(SignalProducer<Void, CarthageError>.empty)
      }
  }

  /// Builds the project in the given directory, using the given options.
  ///
  /// Returns a producer of producers, representing each scheme being built.
  private func buildProjectInDirectoryURL(_ directoryURL: URL, options: Options) -> BuildSchemeProducer {
    let shouldBuildCurrentProject = !options.skipCurrent || options.archive

    let project = Project(directoryURL: directoryURL)
    project.useNetrc = options.useNetrc
    var eventSink = ProjectEventSink(colorOptions: options.colorOptions)
    project.projectEvents.observeValues { eventSink.put($0) }

    let buildProducer = project.loadResolvedCartfile()
      .map { _ in project }
      .flatMapError { error -> SignalProducer<Project, CarthageError> in
        if !shouldBuildCurrentProject {
          return SignalProducer(error: error)
        } else {
          // Ignore Cartfile.resolved loading failure. Assume the user
          // just wants to build the enclosing project.
          return .empty
        }
      }
      .flatMap(.merge) { project in
        project.buildCheckedOutDependenciesWithOptions(options.buildOptions, dependenciesToBuild: options.dependenciesToBuild)
      }

    if !shouldBuildCurrentProject {
      return buildProducer
    } else {
      let currentProducers = buildInDirectory(directoryURL, withOptions: options.buildOptions, rootDirectoryURL: directoryURL)
        .flatMapError { error -> BuildSchemeProducer in
          switch error {
            case let .noSharedFrameworkSchemes(project, _):
              // Log that building the current project is being skipped.
              eventSink.put(.skippedBuilding(project, error.description))
              return .empty

            default:
              return SignalProducer(error: error)
          }
        }
      return buildProducer.concat(currentProducers)
    }
  }

  /// Opens an existing file, if provided, or creates a temporary file if not, returning a handle and the URL to the
  /// file.
  private func openLogFile(_ path: String?) -> SignalProducer<(FileHandle, URL), CarthageError> {
    return SignalProducer { () -> Result<(FileHandle, URL), CarthageError> in
      if let path = path {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        let fileURL = URL(fileURLWithPath: path, isDirectory: false)

        guard let handle = FileHandle(forUpdatingAtPath: path) else {
          let error = NSError(
            domain: Constants.bundleIdentifier,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to open file handle for file at \(path)"]
          )
          return .failure(.writeFailed(fileURL, error))
        }

        return .success((handle, fileURL))
      } else {
        var temporaryDirectoryTemplate: ContiguousArray<CChar>
        temporaryDirectoryTemplate = (NSTemporaryDirectory() as NSString).appendingPathComponent("utica-xcodebuild.XXXXXX.log").utf8CString
        let logFD = temporaryDirectoryTemplate.withUnsafeMutableBufferPointer { (template: inout UnsafeMutableBufferPointer<CChar>) -> Int32 in
          mkstemps(template.baseAddress, 4)
        }
        let logPath = temporaryDirectoryTemplate.withUnsafeBufferPointer { (ptr: UnsafeBufferPointer<CChar>) -> String in
          String(validatingUTF8: ptr.baseAddress!)!
        }
        if logFD < 0 {
          return .failure(.writeFailed(URL(fileURLWithPath: logPath, isDirectory: false), NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)))
        }

        let handle = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
        let fileURL = URL(fileURLWithPath: logPath, isDirectory: false)

        return .success((handle, fileURL))
      }
    }
  }

  /// Opens a file handle for logging, returning the handle and the URL to any
  /// temporary file on disk.
  private func openLoggingHandle(_ options: Options) -> SignalProducer<(FileHandle, URL?), CarthageError> {
    if options.isVerbose {
      let out: (FileHandle, URL?) = (FileHandle.standardOutput, nil)
      return SignalProducer(value: out)
    } else {
      return openLogFile(options.logPath)
        .map { handle, url in (handle, Optional(url)) }
    }
  }
}

public enum BuildPlatform: Equatable {
  case setDisjointWithFlaggedAll(Set<SDK>)
  case all
}

extension BuildPlatform: ArgumentProtocol {
  public static let name = "platform"

  private static func parseSet(_ string: String) throws -> BuildPlatform {
    switch Set(string.split()) {
      case []:
        throw CocoaError(.keyValueValidation)
      case let set:
        guard set != ["all"] else { return .all }

        guard set.isDisjoint(with: ["all"]) else { throw CocoaError(.keyValueValidation) /* because not solely `all` */ }

        let values = try set.lazy.map(SDK.associatedSetOfKnownIn2019YearSDKs).reduce(into: [] as Set<SDK>) {
          guard $1.isEmpty == false else { throw CocoaError(.keyValueValidation) }
          $0.formUnion($1)
        }

        return .setDisjointWithFlaggedAll(values)
    }
  }

  public static func from(string: String) -> BuildPlatform? {
    return try? parseSet(string)
  }
}
