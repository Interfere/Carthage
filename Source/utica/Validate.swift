import Commandant
import Foundation
import ReactiveSwift
import Result
import UticaKit

/// Type that encapsulates the configuration and evaluation of the `validate` subcommand.
public struct ValidateCommand: CommandProtocol {
  public let verb = "validate"
  public let function = "Validate that the versions in Cartfile.resolved are compatible with the Cartfile requirements"

  public func run(_ options: CheckoutCommand.Options) -> Result<Void, CarthageError> {
    return options.loadProject().flatMap(.merge) { (project: Project) in
      project.loadResolvedCartfile().flatMap(.merge, project.validate)
    }
    .on(value: { _ in
      utica.println("No incompatibilities found in Cartfile.resolved")
    })
    .waitOnCommand()
  }
}
