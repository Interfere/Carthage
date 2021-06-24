import Commandant
import Foundation
import ReactiveSwift
import Result
import UticaKit

/// Type that encapsulates the configuration and evaluation of the `bootstrap` subcommand.
public struct BootstrapCommand: CommandProtocol {
  public let verb = "bootstrap"
  public let function = "Check out and build the project's dependencies"

  public func run(_ options: UpdateCommand.Options) -> Result<Void, CarthageError> {
    // Reuse UpdateOptions, since all `bootstrap` flags should correspond to
    // `update` flags.
    return options.loadProject()
      .flatMap(.merge) { project -> SignalProducer<Void, CarthageError> in
        if !FileManager.default.fileExists(atPath: project.resolvedCartfileURL.path) {
          let formatting = options.checkoutOptions.colorOptions.formatting
          utica.println(formatting.bullets + "No Cartfile.resolved found, updating dependencies")
          return project.updateDependencies(
            shouldCheckout: options.checkoutAfterUpdate,
            buildOptions: options.buildOptions
          )
        }

        let checkDependencies: SignalProducer<Void, CarthageError>
        if let depsToUpdate = options.dependenciesToUpdate {
          checkDependencies = project
            .loadResolvedCartfile()
            .flatMap(.concat) { resolvedCartfile -> SignalProducer<Void, CarthageError> in
              let resolvedDependencyNames = resolvedCartfile.dependencies.keys.map { $0.name.lowercased() }
              let unresolvedDependencyNames = Set(depsToUpdate.map { $0.lowercased() }).subtracting(resolvedDependencyNames)

              if !unresolvedDependencyNames.isEmpty {
                return SignalProducer(error: .unresolvedDependencies(unresolvedDependencyNames.sorted()))
              }
              return .empty
            }
        } else {
          checkDependencies = .empty
        }

        let checkoutDependencies: SignalProducer<Void, CarthageError>
        if options.checkoutAfterUpdate {
          checkoutDependencies = project.checkoutResolvedDependencies(options.dependenciesToUpdate, buildOptions: options.buildOptions)
        } else {
          checkoutDependencies = .empty
        }

        return checkDependencies.then(checkoutDependencies)
      }
      .then(options.buildProducer)
      .waitOnCommand()
  }
}
