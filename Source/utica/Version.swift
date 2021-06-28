import Commandant
import Foundation
import Result
import UticaKit

/// Type that encapsulates the configuration and evaluation of the `version` subcommand.
public struct VersionCommand: CommandProtocol {
  public let verb = "version"
  public let function = "Display the current version of Carthage"

  public func run(_: NoOptions<CarthageError>) -> Result<Void, CarthageError> {
    utica.println(CarthageKitVersion.current.value)
    return .success(())
  }
}
