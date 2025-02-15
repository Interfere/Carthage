import Foundation
import Nimble
import Quick
import UticaKit

class VersionSpec: QuickSpec {
  override func spec() {
    it("should parse semantic versions") {
      expect(SemanticVersion.from(PinnedVersion("1.4")).value) == SemanticVersion(1, 4, 0)
      expect(SemanticVersion.from(PinnedVersion("v2.8.9")).value) == SemanticVersion(2, 8, 9)
      expect(SemanticVersion.from(PinnedVersion("2.8.2-alpha")).value) == SemanticVersion(2, 8, 2, preRelease: "alpha")
      expect(SemanticVersion.from(PinnedVersion("2.8.2-alpha+build234")).value) == SemanticVersion(2, 8, 2, preRelease: "alpha", buildMetadata: "build234")
      expect(SemanticVersion.from(PinnedVersion("2.8.2+build234")).value) == SemanticVersion(2, 8, 2, buildMetadata: "build234")
      expect(SemanticVersion.from(PinnedVersion("2.8.2-alpha.2.1.0")).value) == SemanticVersion(2, 8, 2, preRelease: "alpha.2.1.0")
    }

    it("should fail on invalid semantic versions") {
      expect(SemanticVersion.from(PinnedVersion("release#2")).value).to(beNil()) // not a valid SemVer
      expect(SemanticVersion.from(PinnedVersion("v1")).value).to(beNil())
      expect(SemanticVersion.from(PinnedVersion("v2.8-alpha")).value).to(beNil()) // pre-release should be after patch
      expect(SemanticVersion.from(PinnedVersion("v2.8+build345")).value).to(beNil()) // build should be after patch
      expect(SemanticVersion.from(PinnedVersion("null-string-beta-2")).value).to(beNil())
      expect(SemanticVersion.from(PinnedVersion("1.4.5+")).value).to(beNil()) // missing build metadata after '+'
      expect(SemanticVersion.from(PinnedVersion("1.4.5-alpha+")).value).to(beNil()) // missing build metadata after '+'
      expect(SemanticVersion.from(PinnedVersion("1.4.5-alpha#2")).value).to(beNil()) // non alphanumeric are not allowed in pre-release
      expect(SemanticVersion.from(PinnedVersion("1.4.5-alpha.2.01.0")).value).to(beNil()) // numeric identifiers in pre-release
      // version must not include leading zeros
      expect(SemanticVersion.from(PinnedVersion("1.4.5-alpha.2..0")).value).to(beNil()) // empty pre-release component
      expect(SemanticVersion.from(PinnedVersion("1.4.5+build@2")).value).to(beNil()) // non alphanumeric are not allowed in build metadata
      expect(SemanticVersion.from(PinnedVersion("1.4.5-")).value).to(beNil()) // missing pre-release after '-'
      expect(SemanticVersion.from(PinnedVersion("1.4.5-+build43")).value).to(beNil()) // missing pre-release after '-'
      expect(SemanticVersion.from(PinnedVersion("1.４.5")).value).to(beNil()) // Note that the `４` in this string is
      // a fullwidth character, not a halfwidth `4`
      expect(SemanticVersion.from(PinnedVersion("1.8.0.1")).value).to(beNil()) // not a valid SemVer, too many dots
      expect(SemanticVersion.from(PinnedVersion("1.8..1")).value).to(beNil()) // not a valid SemVer, double dots
      expect(SemanticVersion.from(PinnedVersion("1.8.1.")).value).to(beNil()) // not a valid SemVer, ends with dot
      expect(SemanticVersion.from(PinnedVersion("1.8.")).value).to(beNil()) // not a valid SemVer, ends with dot
      expect(SemanticVersion.from(PinnedVersion("1.")).value).to(beNil()) // not a valid SemVer, ends with dot
      expect(SemanticVersion.from(PinnedVersion("1.8.0.alpha")).value).to(beNil()) // not a valid SemVer, pre-release is dot-separated
    }
  }
}

class VersionSpecifierSpec: QuickSpec {
  override func spec() {
    func testIntersection(_ lhs: VersionSpecifier, _ rhs: VersionSpecifier, expected: VersionSpecifier?) {
      if let expected = expected {
        expect(intersection(lhs, rhs)) == expected
        expect(intersection(rhs, lhs)) == expected
      } else {
        expect(intersection(lhs, rhs)).to(beNil())
        expect(intersection(rhs, lhs)).to(beNil())
      }
    }

    describe("isSatisfied(by:)") {
      let v0_1_0 = PinnedVersion("0.1.0")
      let v0_1_0_pre23 = PinnedVersion("0.1.0-pre23")
      let v0_1_0_build123 = PinnedVersion("v0.1.0+build123")
      let v0_1_1 = PinnedVersion("0.1.1")
      let v0_2_0 = PinnedVersion("0.2.0")
      let v0_2_0_candidate = PinnedVersion("0.2.0-candidate")
      let v1_3_2 = PinnedVersion("1.3.2")
      let v2_0_2 = PinnedVersion("2.0.2")
      let v2_1_1 = PinnedVersion("2.1.1")
      let v2_1_1_build3345 = PinnedVersion("2.1.1+build3345")
      let v2_1_1_alpha = PinnedVersion("2.1.1-alpha")
      let v2_2_0 = PinnedVersion("2.2.0")
      let v3_0_0 = PinnedVersion("3.0.0")
      let nonSemantic = PinnedVersion("new-version")

      it("should allow all versions for .any") {
        let specifier = VersionSpecifier.any
        expect(specifier.isSatisfied(by: v1_3_2)) == true
        expect(specifier.isSatisfied(by: v2_0_2)) == true
        expect(specifier.isSatisfied(by: v2_1_1)) == true
        expect(specifier.isSatisfied(by: v2_2_0)) == true
        expect(specifier.isSatisfied(by: v3_0_0)) == true
        expect(specifier.isSatisfied(by: v0_1_0)) == true
        expect(specifier.isSatisfied(by: v0_1_0_build123)) == true
        expect(specifier.isSatisfied(by: v2_1_1_build3345)) == true
      }

      it("should allow a non-semantic version for Any") {
        let specifier = VersionSpecifier.any
        expect(specifier.isSatisfied(by: nonSemantic)) == true
      }

      it("should not allow a pre-release version for Any") {
        let specifier = VersionSpecifier.any
        expect(specifier.isSatisfied(by: v2_1_1_alpha)) == false
      }

      it("should allow greater or equal versions for .atLeast") {
        let specifier = VersionSpecifier.atLeast(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: v1_3_2)) == false
        expect(specifier.isSatisfied(by: v2_0_2)) == false
        expect(specifier.isSatisfied(by: v2_1_1)) == true
        expect(specifier.isSatisfied(by: v2_2_0)) == true
        expect(specifier.isSatisfied(by: v3_0_0)) == true
      }

      it("should allow a non-semantic version for .atLeast") {
        let specifier = VersionSpecifier.atLeast(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: nonSemantic)) == true
      }

      it("should not allow for a pre-release of the same non-pre-release version for .atLeast") {
        let specifier = VersionSpecifier.atLeast(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: v2_1_1_alpha)) == false
      }

      it("should allow for a build version of the same version for .atLeast") {
        let specifier = VersionSpecifier.atLeast(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: v2_1_1_build3345)) == true
      }

      it("should not allow for a build version of a different version for .atLeast") {
        let specifier = VersionSpecifier.atLeast(SemanticVersion.from(v3_0_0).value!)
        expect(specifier.isSatisfied(by: v2_1_1_build3345)) == false
      }

      it("should allow for a build version of the same version for .compatibleWith") {
        let specifier = VersionSpecifier.compatibleWith(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: v2_1_1_build3345)) == true
      }

      it("should not allow for a build version of a different version for .compatibleWith") {
        let specifier = VersionSpecifier.compatibleWith(SemanticVersion.from(v1_3_2).value!)
        expect(specifier.isSatisfied(by: v2_1_1_build3345)) == false
      }

      it("should not allow for a greater pre-release version for .atLeast") {
        let specifier = VersionSpecifier.atLeast(SemanticVersion.from(v2_0_2).value!)
        expect(specifier.isSatisfied(by: v2_1_1_alpha)) == false
      }

      it("should allow greater or equal minor and patch versions for .compatibleWith") {
        let specifier = VersionSpecifier.compatibleWith(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: v1_3_2)) == false
        expect(specifier.isSatisfied(by: v2_0_2)) == false
        expect(specifier.isSatisfied(by: v2_1_1)) == true
        expect(specifier.isSatisfied(by: v2_2_0)) == true
        expect(specifier.isSatisfied(by: v3_0_0)) == false
      }

      it("should allow a non-semantic version for .compatibleWith") {
        let specifier = VersionSpecifier.compatibleWith(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: nonSemantic)) == true
      }

      it("should not allow equal minor and patch pre-release version for .compatibleWith") {
        let specifier = VersionSpecifier.compatibleWith(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: v2_1_1_alpha)) == false
      }

      it("should only allow exact versions for .exactly") {
        let specifier = VersionSpecifier.exactly(SemanticVersion.from(v2_2_0).value!)
        expect(specifier.isSatisfied(by: v1_3_2)) == false
        expect(specifier.isSatisfied(by: v2_0_2)) == false
        expect(specifier.isSatisfied(by: v2_1_1)) == false
        expect(specifier.isSatisfied(by: v2_2_0)) == true
        expect(specifier.isSatisfied(by: v3_0_0)) == false
      }

      it("should not allow a build version of a different version for .exactly") {
        let specifier = VersionSpecifier.exactly(SemanticVersion.from(v1_3_2).value!)
        expect(specifier.isSatisfied(by: v0_1_0_build123)) == false
      }

      it("should not allow a build version of the same version for .exactly") {
        let specifier = VersionSpecifier.exactly(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: v2_1_1_build3345)) == false
      }

      it("should allow for a non-semantic version for .exactly") {
        let specifier = VersionSpecifier.exactly(SemanticVersion.from(v2_1_1).value!)
        expect(specifier.isSatisfied(by: nonSemantic)) == true
      }

      it("should not allow any pre-release versions to satisfy 0.x") {
        let specifier = VersionSpecifier.compatibleWith(SemanticVersion.from(v0_1_0).value!)
        expect(specifier.isSatisfied(by: v0_1_0_pre23)) == false
      }

      it("should not allow a pre-release versions of a different version to satisfy 0.x") {
        let specifier = VersionSpecifier.compatibleWith(SemanticVersion.from(v0_1_0).value!)
        expect(specifier.isSatisfied(by: v0_2_0_candidate)) == false
      }

      it("should allow only greater patch versions to satisfy 0.x") {
        let specifier = VersionSpecifier.compatibleWith(SemanticVersion.from(v0_1_0).value!)
        expect(specifier.isSatisfied(by: v0_1_0)) == true
        expect(specifier.isSatisfied(by: v0_1_1)) == true
        expect(specifier.isSatisfied(by: v0_2_0)) == false
      }
    }

    describe("intersection") {
      let v0_1_0 = SemanticVersion(0, 1, 0)
      let v0_1_1 = SemanticVersion(0, 1, 1)
      let v0_2_0 = SemanticVersion(0, 2, 0)
      let v1_3_2 = SemanticVersion(1, 3, 2)
      let v2_1_1 = SemanticVersion(2, 1, 1)
      let v2_2_0 = SemanticVersion(2, 2, 0)
      let v2_2_0_b421 = SemanticVersion(2, 2, 0, buildMetadata: "b421")
      let v2_2_0_alpha = SemanticVersion(2, 2, 0, preRelease: "alpha")

      it("should return the tighter specifier when one is .any") {
        testIntersection(.any, .any, expected: .any)
        testIntersection(.any, .atLeast(v1_3_2), expected: .atLeast(v1_3_2))
        testIntersection(.any, .compatibleWith(v1_3_2), expected: .compatibleWith(v1_3_2))
        testIntersection(.any, .exactly(v1_3_2), expected: .exactly(v1_3_2))
        testIntersection(.any, .exactly(v2_2_0_b421), expected: .exactly(v2_2_0_b421))
        testIntersection(.any, .exactly(v2_2_0_alpha), expected: .exactly(v2_2_0_alpha))
      }

      it("should return the higher specifier when one is .atLeast") {
        testIntersection(.atLeast(v1_3_2), .atLeast(v1_3_2), expected: .atLeast(v1_3_2))
        testIntersection(.atLeast(v1_3_2), .atLeast(v2_1_1), expected: .atLeast(v2_1_1))
        testIntersection(.atLeast(v2_2_0), .atLeast(v2_2_0_b421), expected: .atLeast(v2_2_0))
        testIntersection(.atLeast(v2_2_0), .atLeast(v2_2_0_alpha), expected: .atLeast(v2_2_0))
        testIntersection(.atLeast(v1_3_2), .compatibleWith(v2_1_1), expected: .compatibleWith(v2_1_1))
        testIntersection(.atLeast(v2_1_1), .compatibleWith(v2_2_0), expected: .compatibleWith(v2_2_0))
        testIntersection(.atLeast(v2_2_0), .compatibleWith(v2_2_0_b421), expected: .compatibleWith(v2_2_0))
        testIntersection(.atLeast(v2_2_0), .compatibleWith(v2_2_0_alpha), expected: .compatibleWith(v2_2_0))
        testIntersection(.atLeast(v2_2_0_alpha), .compatibleWith(v2_2_0), expected: .compatibleWith(v2_2_0))
        testIntersection(.atLeast(v1_3_2), .exactly(v2_2_0), expected: .exactly(v2_2_0))
        testIntersection(.atLeast(v2_2_0), .exactly(v2_2_0_b421), expected: .exactly(v2_2_0_b421))
        testIntersection(.atLeast(v2_2_0_b421), .exactly(v2_2_0), expected: .exactly(v2_2_0))
        testIntersection(.atLeast(v2_2_0_alpha), .exactly(v2_2_0), expected: .exactly(v2_2_0))
      }

      it("should return the higher minor or patch version when one is .compatibleWith") {
        testIntersection(.compatibleWith(v1_3_2), .compatibleWith(v1_3_2), expected: .compatibleWith(v1_3_2))
        testIntersection(.compatibleWith(v1_3_2), .compatibleWith(v2_1_1), expected: nil)
        testIntersection(.compatibleWith(v2_1_1), .compatibleWith(v2_2_0), expected: .compatibleWith(v2_2_0))
        testIntersection(.compatibleWith(v2_1_1), .exactly(v2_2_0), expected: .exactly(v2_2_0))
        testIntersection(.compatibleWith(v2_2_0), .exactly(v2_2_0_alpha), expected: nil)
        testIntersection(.compatibleWith(v2_2_0), .exactly(v2_2_0_b421), expected: .exactly(v2_2_0_b421))
        testIntersection(.compatibleWith(v2_2_0_alpha), .exactly(v2_2_0), expected: .exactly(v2_2_0))
        testIntersection(.compatibleWith(v2_2_0_b421), .exactly(v2_2_0), expected: .exactly(v2_2_0))
      }

      it("should only match exact specifiers for .exactly") {
        testIntersection(.exactly(v1_3_2), .atLeast(v2_1_1), expected: nil)
        testIntersection(.exactly(v2_1_1), .compatibleWith(v1_3_2), expected: nil)
        testIntersection(.exactly(v2_1_1), .compatibleWith(v2_2_0), expected: nil)
        testIntersection(.exactly(v1_3_2), .exactly(v1_3_2), expected: VersionSpecifier.exactly(v1_3_2))
        testIntersection(.exactly(v2_1_1), .exactly(v1_3_2), expected: nil)
        testIntersection(.exactly(v2_2_0_alpha), .exactly(v2_2_0), expected: nil)
        testIntersection(.exactly(v2_2_0_b421), .exactly(v2_2_0), expected: nil)
      }

      it("should let ~> 0.1.1 be compatible with 0.1.2, but not 0.2") {
        testIntersection(.compatibleWith(v0_1_0), .compatibleWith(v0_1_1), expected: .compatibleWith(v0_1_1))
        testIntersection(.compatibleWith(v0_1_0), .compatibleWith(v0_2_0), expected: nil)
      }
    }
  }
}
