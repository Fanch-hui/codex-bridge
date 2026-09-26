import Foundation
import Testing

@testable import BridgePiRPC

struct PiRuntimeResourcesTests {
  @Test func validatesEveryPackagedExtensionRuntimeArtifact() throws {
    let resources = try PiRuntimeResources.load(directory: nil)
    #expect(URL(fileURLWithPath: resources.entryPath).lastPathComponent == "index.mjs")
    #expect(resources.validatedResources.count == 12)
  }
}
