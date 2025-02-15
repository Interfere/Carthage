import Commandant
import Curry
import Foundation
import ReactiveSwift
import Result
import UticaKit

/// Type that encapsulates the configuration and evaluation of the `update` subcommand.
public struct UpdateCommand: CommandProtocol {
  public struct Options: OptionsProtocol {
    public let checkoutAfterUpdate: Bool
    public let buildAfterUpdate: Bool
    public let isVerbose: Bool
    public let logPath: String?
    public let useNetrc: Bool
    public let buildOptions: UticaKit.BuildOptions
    public let checkoutOptions: CheckoutCommand.Options
    public let dependenciesToUpdate: [String]?

    /// The build options corresponding to these options.
    public var buildCommandOptions: BuildCommand.Options {
      return BuildCommand.Options(
        buildOptions: buildOptions,
        skipCurrent: true,
        colorOptions: checkoutOptions.colorOptions,
        isVerbose: isVerbose,
        directoryPath: checkoutOptions.directoryPath,
        logPath: logPath,
        archive: false,
        useNetrc: useNetrc,
        dependenciesToBuild: dependenciesToUpdate
      )
    }

    /// If `checkoutAfterUpdate` and `buildAfterUpdate` are both true, this will
    /// be a producer representing the work necessary to build the project.
    ///
    /// Otherwise, this producer will be empty.
    public var buildProducer: SignalProducer<Void, CarthageError> {
      if checkoutAfterUpdate, buildAfterUpdate {
        return BuildCommand().buildWithOptions(buildCommandOptions)
      } else {
        return .empty
      }
    }

    private init(
      checkoutAfterUpdate: Bool,
      buildAfterUpdate: Bool,
      isVerbose: Bool,
      logPath: String?,
      useNetrc: Bool,
      buildOptions: BuildOptions,
      checkoutOptions: CheckoutCommand.Options
    ) {
      self.checkoutAfterUpdate = checkoutAfterUpdate
      self.buildAfterUpdate = buildAfterUpdate
      self.isVerbose = isVerbose
      self.logPath = logPath
      self.useNetrc = useNetrc
      self.buildOptions = buildOptions
      self.checkoutOptions = checkoutOptions
      self.dependenciesToUpdate = checkoutOptions.dependenciesToCheckout
    }

    public static func evaluate(_ mode: CommandMode) -> Result<Options, CommandantError<CarthageError>> {
      let buildDescription = "skip the building of dependencies after updating\n(ignored if --no-checkout option is present)"

      let dependenciesUsage = "the dependency names to update, checkout and build"
      let netrcOption = Option(
        key: "use-netrc",
        defaultValue: false,
        usage: "use authentication credentials from ~/.netrc file when downloading binary only frameworks"
      )

      // Swift 5.1 workaround
      // Carthage Issue: https://github.com/Carthage/Carthage/issues/2831
      // Swift Compiler Bug: https://bugs.swift.org/browse/SR-11423
      let defaultLogPath: String? = nil

      return curry(Options.init)
        <*> mode <| Option<Bool>(key: "checkout", defaultValue: true, usage: "skip the checking out of dependencies after updating")
        <*> mode <| Option<Bool>(key: "build", defaultValue: true, usage: buildDescription)
        <*> mode <| Option<Bool>(key: "verbose", defaultValue: false, usage: "print xcodebuild output inline (ignored if --no-build option is present)")
        <*> mode <| Option<String?>(key: "log-path", defaultValue: defaultLogPath, usage: "path to the xcode build output. A temporary file is used by default")
        <*> mode <| netrcOption
        <*> BuildOptions.evaluate(mode, addendum: "\n(ignored if --no-build option is present)")
        <*> CheckoutCommand.Options.evaluate(mode, dependenciesUsage: dependenciesUsage)
    }

    /// Attempts to load the project referenced by the options, and configure it
    /// accordingly.
    public func loadProject() -> SignalProducer<Project, CarthageError> {
      return checkoutOptions.loadProject()
    }
  }

  public let verb = "update"
  public let function = "Update and rebuild the project's dependencies"

  public func run(_ options: Options) -> Result<Void, CarthageError> {
    return options.loadProject()
      .flatMap(.merge) { project -> SignalProducer<Void, CarthageError> in

        project.useNetrc = options.useNetrc

        let checkDependencies: SignalProducer<Void, CarthageError>
        if let depsToUpdate = options.dependenciesToUpdate {
          checkDependencies = project
            .loadCombinedCartfile()
            .flatMap(.concat) { cartfile -> SignalProducer<Void, CarthageError> in
              let dependencyNames = cartfile.dependencies.keys.map { $0.name.lowercased() }
              let unknownDependencyNames = Set(depsToUpdate.map { $0.lowercased() }).subtracting(dependencyNames)

              if !unknownDependencyNames.isEmpty {
                return SignalProducer(error: .unknownDependencies(unknownDependencyNames.sorted()))
              }
              return .empty
            }
        } else {
          checkDependencies = .empty
        }

        let updateDependencies = project.updateDependencies(
          shouldCheckout: options.checkoutAfterUpdate,
          buildOptions: options.buildOptions,
          dependenciesToUpdate: options.dependenciesToUpdate
        )

        return checkDependencies.then(updateDependencies)
      }
      .then(options.buildProducer)
      .waitOnCommand()
  }
}
