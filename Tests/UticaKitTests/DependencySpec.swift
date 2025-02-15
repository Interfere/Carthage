import Foundation
import Nimble
import Quick
import Tentacle
@testable import UticaKit

class DependencySpec: QuickSpec {
  override func spec() {
    var dependencyType: String!

    sharedExamples("invalid dependency") { (sharedExampleContext: @escaping SharedExampleContext) in

      beforeEach {
        guard let type = sharedExampleContext()["dependencyType"] as? String else {
          fail("no dependency type")
          return
        }

        dependencyType = type
      }

      it("should fail without dependency") {
        let scanner = Scanner(string: dependencyType)

        let error = Dependency.from(scanner).error

        let expectedError = ScannableError(message: "expected string after dependency type", currentLine: dependencyType)
        expect(error) == expectedError
      }

      it("should fail without closing quote on dependency") {
        let scanner = Scanner(string: "\(dependencyType!) \"dependency")

        let error = Dependency.from(scanner).error

        let expectedError = ScannableError(message: "empty or unterminated string after dependency type", currentLine: "\(dependencyType!) \"dependency")
        expect(error) == expectedError
      }

      it("should fail with empty dependency") {
        let scanner = Scanner(string: "\(dependencyType!) \" \"")

        let error = Dependency.from(scanner).error

        let expectedError = ScannableError(message: "empty or unterminated string after dependency type", currentLine: "\(dependencyType!) \" \"")
        expect(error) == expectedError
      }
    }

    describe("name") {
      context("github") {
        it("should equal the name of a github.com repo") {
          let dependency = Dependency.gitHub(.dotCom, Repository(owner: "owner", name: "name"))

          expect(dependency.name) == "name"
        }

        it("should equal the name of an enterprise github repo") {
          let enterpriseRepo = Repository(
            owner: "owner",
            name: "name"
          )

          let dependency = Dependency.gitHub(.enterprise(url: URL(string: "http://server.com")!), enterpriseRepo)

          expect(dependency.name) == "name"
        }
      }

      context("git") {
        it("should be the last component of the URL") {
          let dependency = Dependency.git(GitURL("ssh://server.com/myproject"))

          expect(dependency.name) == "myproject"
        }

        it("should not include the trailing git suffix") {
          let dependency = Dependency.git(GitURL("ssh://server.com/myproject.git"))

          expect(dependency.name) == "myproject"
        }

        it("should be the entire URL string if there is no last component") {
          let dependency = Dependency.git(GitURL("whatisthisurleven"))

          expect(dependency.name) == "whatisthisurleven"
        }

        context("when a relative local path with dots is given") {
          let fileManager = FileManager.default
          var startingDirectory: String!
          var temporaryDirectoryURL: URL!

          beforeEach {
            startingDirectory = fileManager.currentDirectoryPath
            temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            fileManager.changeCurrentDirectoryPath(temporaryDirectoryURL.path)
          }

          afterEach {
            fileManager.changeCurrentDirectoryPath(startingDirectory)
          }

          it("should sanitize even despite the given URL string being (pathologically) solely the nul character") {
            // this project would not be able to be checked out

            let dependency = Dependency.git(GitURL("\u{0000}"))

            expect(dependency.name) == "␀"
          }

          it("should sanitize even despite the given URL string being (pathologically) solely the nul character and path separators") {
            // this project would not be able to be checked out

            let dependency = Dependency.git(GitURL("/\u{0000}/"))

            expect(dependency.name) == "␀"
          }

          it("should sanitize even despite the given URL string containing (pathologically) the nul character") {
            // this project would not be able to be checked out

            let dependency = Dependency.git(GitURL("./../../../../../\u{0000}myproject"))

            expect(dependency.name) == "␀myproject"
          }

          it("should sanitize if the given URL string is (pathologically) «.»") {
            let dependency = Dependency.git(GitURL("."))

            expect(dependency.name) == "\u{FF0E}"
          }

          it("should be the directory name if the given URL string is (pathologically) prefixed by «./»") {
            let dependency = Dependency.git(GitURL("./myproject"))

            expect(dependency.name) == "myproject"
          }

          it("should sanitize if the given URL string is (pathologically) «..»") {
            let dependency = Dependency.git(GitURL(".."))

            expect(dependency.name) == "\u{FF0E}\u{FF0E}"
          }

          it("should sanitize if the given URL string is (pathologically) «...git»") {
            let dependency = Dependency.git(GitURL("...git"))

            expect(dependency.name) == "\u{FF0E}\u{FF0E}"
          }

          it("should be the directory name if the given URL string is (pathologically) prefixed by «../» with (pathologically) no URL scheme") {
            let dependency = Dependency.git(GitURL("../myproject"))

            expect(dependency.name) == "myproject"
          }

          it("should sanitize if the given URL string is (pathologically) suffixed by «/..»") {
            let dependency = Dependency.git(GitURL("../myproject/.."))

            expect(dependency.name) == "\u{FF0E}\u{FF0E}"
          }
        }
      }

      context("binary") {
        it("should be the last component of the URL") {
          let url = URL(string: "https://server.com/myproject")!
          let binary = BinaryURL(url: url, resolvedDescription: url.description)
          let dependency = Dependency.binary(binary)

          expect(dependency.name) == "myproject"
        }

        it("should not include the trailing git suffix") {
          let url = URL(string: "https://server.com/myproject.json")!
          let binary = BinaryURL(url: url, resolvedDescription: url.description)
          let dependency = Dependency.binary(binary)

          expect(dependency.name) == "myproject"
        }
      }
    }

    describe("from") {
      context("github") {
        it("should read a github.com dependency") {
          let scanner = Scanner(string: "github \"ReactiveCocoa/ReactiveCocoa\"")

          let dependency = Dependency.from(scanner).value

          let expectedRepo = Repository(owner: "ReactiveCocoa", name: "ReactiveCocoa")
          expect(dependency) == .gitHub(.dotCom, expectedRepo)
        }

        it("should read a github.com dependency with full url") {
          let scanner = Scanner(string: "github \"https://github.com/ReactiveCocoa/ReactiveCocoa\"")

          let dependency = Dependency.from(scanner).value

          let expectedRepo = Repository(owner: "ReactiveCocoa", name: "ReactiveCocoa")
          expect(dependency) == .gitHub(.dotCom, expectedRepo)
        }

        it("should read an enterprise github dependency") {
          let scanner = Scanner(string: "github \"http://mysupercoolinternalwebhost.com/ReactiveCocoa/ReactiveCocoa\"")

          let dependency = Dependency.from(scanner).value

          let expectedRepo = Repository(
            owner: "ReactiveCocoa",
            name: "ReactiveCocoa"
          )
          expect(dependency) == .gitHub(.enterprise(url: URL(string: "http://mysupercoolinternalwebhost.com")!), expectedRepo)
        }

        it("should fail with invalid github.com dependency") {
          let scanner = Scanner(string: "github \"Whatsthis\"")

          let error = Dependency.from(scanner).error

          let expectedError = ScannableError(message: "invalid GitHub repository identifier \"Whatsthis\"")
          expect(error) == expectedError
        }

        it("should fail with invalid enterprise github dependency") {
          let scanner = Scanner(string: "github \"http://mysupercoolinternalwebhost.com/ReactiveCocoa\"")

          let error = Dependency.from(scanner).error

          let expectedError = ScannableError(message: "invalid GitHub repository identifier \"http://mysupercoolinternalwebhost.com/ReactiveCocoa\"")
          expect(error) == expectedError
        }

        itBehavesLike("invalid dependency") { ["dependencyType": "github"] }
      }

      context("git") {
        it("should read a git URL") {
          let scanner = Scanner(string: "git \"mygiturl\"")

          let dependency = Dependency.from(scanner).value

          expect(dependency) == .git(GitURL("mygiturl"))
        }

        it("should read a git dependency as github") {
          let scanner = Scanner(string: "git \"ssh://git@github.com:owner/name\"")

          let dependency = Dependency.from(scanner).value

          let expectedRepo = Repository(owner: "owner", name: "name")

          expect(dependency) == .gitHub(.dotCom, expectedRepo)
        }

        it("should read a git dependency as github") {
          let scanner = Scanner(string: "git \"https://github.com/owner/name\"")

          let dependency = Dependency.from(scanner).value

          let expectedRepo = Repository(owner: "owner", name: "name")

          expect(dependency) == .gitHub(.dotCom, expectedRepo)
        }

        it("should read a git dependency as github") {
          let scanner = Scanner(string: "git \"git@github.com:owner/name\"")

          let dependency = Dependency.from(scanner).value

          let expectedRepo = Repository(owner: "owner", name: "name")

          expect(dependency) == .gitHub(.dotCom, expectedRepo)
        }

        itBehavesLike("invalid dependency") { ["dependencyType": "git"] }
      }

      context("binary") {
        it("should read a URL with https scheme") {
          let scanner = Scanner(string: "binary \"https://mysupercoolinternalwebhost.com/\"")

          let dependency = Dependency.from(scanner).value
          let url = URL(string: "https://mysupercoolinternalwebhost.com/")!
          let binary = BinaryURL(url: url, resolvedDescription: url.description)

          expect(dependency) == .binary(binary)
        }

        it("should read a URL with file scheme") {
          let scanner = Scanner(string: "binary \"file:///my/domain/com/framework.json\"")

          let dependency = Dependency.from(scanner).value
          let url = URL(string: "file:///my/domain/com/framework.json")!
          let binary = BinaryURL(url: url, resolvedDescription: url.description)

          expect(dependency) == .binary(binary)
        }

        it("should read a URL with relative file path") {
          let relativePath = "my/relative/path/framework.json"
          let scanner = Scanner(string: "binary \"\(relativePath)\"")

          let workingDirectory = URL(string: "file:///current/working/directory/")!
          let dependency = Dependency.from(scanner, base: workingDirectory).value

          let url = URL(string: "file:///current/working/directory/my/relative/path/framework.json")!
          let binary = BinaryURL(url: url, resolvedDescription: relativePath)

          expect(dependency) == .binary(binary)
        }

        it("should read a URL with an absolute path") {
          let absolutePath = "/my/absolute/path/framework.json"
          let scanner = Scanner(string: "binary \"\(absolutePath)\"")

          let dependency = Dependency.from(scanner).value
          let url = URL(string: "file:///my/absolute/path/framework.json")!
          let binary = BinaryURL(url: url, resolvedDescription: absolutePath)

          expect(dependency) == .binary(binary)
        }

        it("should fail with invalid URL") {
          let scanner = Scanner(string: "binary \"nop@%@#^@e\"")

          let error = Dependency.from(scanner).error

          expect(error) == ScannableError(message: "invalid URL found for dependency type `binary`", currentLine: "binary \"nop@%@#^@e\"")
        }

        itBehavesLike("invalid dependency") { ["dependencyType": "binary"] }
      }
    }
  }
}
