import Foundation
import ReactiveSwift
import ReactiveTask
import Result

/// Loads a bundle directory from a given URL and sends Bundle objects for each framework in it.
///
/// If `url` is an XCFramework, sends a Bundle for each embedded framework bundle.
/// If `url` is a framework bundle, sends a Bundle instance for the directory.
/// - parameter url: A framework or xcframework URL to load from.
/// - parameter platformName: If given, only sends bundles from an XCFramework with a matching `SupportedPlatform`.
/// - parameter variant: If given along with `platformName`, only sends bundles from an XCFramework with a matching `SupportedPlatformVariant`.
public func frameworkBundlesInURL(_ url: URL, compatibleWith platformName: String? = nil, variant: String? = nil) -> SignalProducer<Bundle, DecodingError> {
	guard let bundle = Bundle(url: url) else {
		return .empty
	}

	switch bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String {
	case "XFWK":
		let decoder = PropertyListDecoder()
		let infoData = bundle.infoDictionary.flatMap({ try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }) ?? Data()
		let xcframework = Result<XCFramework, DecodingError>(catching: { try decoder.decode(XCFramework.self, from: infoData) })
		return SignalProducer(result: xcframework)
			.map({ $0.availableLibraries }).flatten()
			.filter { library in
				guard let platformName = platformName else { return true }
				return library.supportedPlatform == platformName && library.supportedPlatformVariant == variant
			}
			.map({ Bundle(url: url.appendingPathComponent($0.identifier).appendingPathComponent($0.path)) })
			.skipNil()
	default: // Typically "FMWK" but not required
		return SignalProducer(value: bundle)
	}
}

/// Create or update an xcframework from a framework bundle and its debug information. Any existing framework with the
/// same platform information will be replaced.
///
/// XCFrameworks cannot be updated in-place, so this works by taking existing frameworks and debug info from the
/// xcframework, adding in the given framework and debug info, and writing it all into an a new xcframework bundle.
///
/// Existing libraries in the xcframework with the same `platformName` and `variant` will be removed, so this function
/// can be used to update a single library in the xcframework with a new build.
/// - parameter xcframeworkURL: An xcframework which read from and merged into.
/// - parameter framework: The new framework to merge.
/// - parameter debugSymbols: dSYMs and bcsymbolmaps for `framework`.
/// - parameter platformName: The OS portion of the platform triple. Libraries in the xcframework with a matching platform name and variant will be replaced.
/// - parameter variant: The environment portion of the platform triple (i.e. "simulator" or nil). Libraries in the xcframework with a matching platform name and variant will be replaced.
/// - parameter outputURL: Location to write the merged xcframework to.
public func mergeIntoXCFramework(
	_ xcframeworkURL: URL,
	framework: URL,
	debugSymbols: [URL],
	platformName: String,
	variant: String?,
	outputURL: URL
) -> SignalProducer<URL, TaskError> {
	let baseArguments = ["xcodebuild", "-create-xcframework", "-allow-internal-distribution", "-output", outputURL.path]
	let newLibraryArguments = ["-framework", framework.path] + debugSymbols.flatMap { ["-debug-symbols", $0.path] }

  let buildExistingLibraryArguments: SignalProducer<[String], Never> = SignalProducer {
    Result(catching: { try loadXCFramework(url: xcframeworkURL) })
  }
  .flatMap(.concat) { framework -> SignalProducer<XCFramework.Library, Swift.Error> in
    SignalProducer(framework.availableLibraries.filter { library in
      library.supportedPlatform != platformName || library.supportedPlatformVariant != variant
    })
  }
  .attemptMap { library in
    Result(catching: { try buildArguments(from: library, baseUrl: xcframeworkURL) })
  }
  .flatMapError { _ in SignalProducer(value: []) }

	return buildExistingLibraryArguments.promoteError().flatMap(.concat) { existingLibraryArguments in
		let arguments = baseArguments + newLibraryArguments + existingLibraryArguments
		return Task("/usr/bin/xcrun", arguments: arguments).launch().ignoreTaskData().map { _ in outputURL }
	}
}


/// Attempts to load XCFramework at url
///
/// - Parameter url: URL to XCFramework
/// - Returns: `XCFramework` entity
private func loadXCFramework(url: URL) throws -> XCFramework {
  let decoder = PropertyListDecoder()
  let infoData = try Data(contentsOf: url.appendingPathComponent("Info.plist"))
  return try decoder.decode(XCFramework.self, from: infoData)
}

/// Attempts to build arguments for each library
private func buildArguments(from library: XCFramework.Library, baseUrl: URL) throws -> [String] {
  let libraryURL = baseUrl.appendingPathComponent(library.identifier)
  var arguments = ["-framework", libraryURL.appendingPathComponent(library.path).path]

  if let debugSymbolsPath = library.debugSymbolsPath {
    let dsyms = try FileManager.default.contentsOfDirectory(
     at: libraryURL.appendingPathComponent(debugSymbolsPath),
     includingPropertiesForKeys: nil
    )
    arguments += dsyms.flatMap { ["-debug-symbols", $0.path] }
  }

  if let bitcodeSymbolMapsPath = library.bitcodeSymbolMapsPath {
    let bcsymbolmaps = try FileManager.default.contentsOfDirectory(
      at: libraryURL.appendingPathComponent(bitcodeSymbolMapsPath),
      includingPropertiesForKeys: nil
    )
    arguments += bcsymbolmaps.flatMap { ["-debug-symbols", $0.path] }
  }
  return arguments
}

struct XCFramework: Decodable {
	let availableLibraries: [Library]
	let version: String

	struct Library: Decodable {
		let identifier: String
		let path: String
		let supportedPlatform: String
		let supportedPlatformVariant: String?
		let debugSymbolsPath: String?
		let bitcodeSymbolMapsPath: String?

		enum CodingKeys: String, CodingKey {
			case identifier = "LibraryIdentifier"
			case path = "LibraryPath"
			case supportedPlatform = "SupportedPlatform"
			case supportedPlatformVariant = "SupportedPlatformVariant"
			case debugSymbolsPath = "DebugSymbolsPath"
			case bitcodeSymbolMapsPath = "BitcodeSymbolMapsPath"
		}
	}

	enum CodingKeys: String, CodingKey {
		case availableLibraries = "AvailableLibraries"
		case version = "XCFrameworkFormatVersion"
	}
}
