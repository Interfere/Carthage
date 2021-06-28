import Foundation
import Nimble
import Quick
import ReactiveSwift
import Result
@testable import UticaKit

class MachHeaderSpec: QuickSpec {
  override func spec() {
    describe("headers") {
      it("should list all mach headers for a given Mach-O file") {
        let directoryURL = Bundle(for: type(of: self)).url(forResource: "Alamofire.framework", withExtension: nil)!

        let result = UticaKit
          .MachHeader
          .headers(forMachOFileAtUrl: directoryURL.appendingPathComponent("Alamofire"))
          .collect()
          .single()

        expect(result?.value?.count) == 36
      }
    }
  }
}
