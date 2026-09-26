import BridgeSecurity
import Foundation

struct PiRuntimeResources {
  let entryPath: String
  let entry: SecureFileArtifactSnapshot
  let validatedResources: [SecureFileArtifactSnapshot]

  static func load(directory: String?) throws -> PiRuntimeResources {
    let url: URL
    if let directory {
      url = URL(fileURLWithPath: directory, isDirectory: true)
    } else if let resource = Bundle.module.resourceURL?.appendingPathComponent("PiBridgeExtension")
    {
      url = resource
    } else {
      throw PiRPCError.invalidArgument("pi_extension_missing")
    }
    let resources = try expectedHashes.keys.sorted().map { name in
      let maximumBytes: UInt64 =
        name == "mcp-client.bundle.cjs"
        ? 2 * 1_024 * 1_024 : 512 * 1_024
      let snapshot = try SecureFileArtifactSnapshot.capture(
        at: url.appendingPathComponent(name).path, maximumBytes: maximumBytes)
      guard snapshot.sha256 == expectedHashes[name] else {
        throw PiRPCError.invalidArgument("pi_extension_identity")
      }
      return (name, snapshot)
    }
    guard let entry = resources.first(where: { $0.0 == "index.mjs" })?.1 else {
      throw PiRPCError.invalidArgument("pi_extension_identity")
    }
    return PiRuntimeResources(
      entryPath: entry.canonicalPath, entry: entry, validatedResources: resources.map(\.1))
  }

  private static let expectedHashes = [
    "index.mjs": "27ee5f7951dbe5b929c8b8f27780466fefaa60d4ad5ae65315c2a2859f3aaaa7",
    "policy.mjs": "44ce5a7801be822bc0f09793cff19554ec04e5b27d55788341448597773820f4",
    "plan.mjs": "c0b99244c69ff306cb40c8b43db9ca2e0ad0850797474a384e94554ad82406f2",
    "ask-user.mjs": "8872ba9a6ab74f621d2113dcdf255c89cd35b1d81ea79b2740b96c73fc5535c9",
    "mcp.mjs": "13a7ea8af6fed5f010ba8480228a5b016c84d5b682c6296f67c52d0740355f99",
    "subtask.mjs": "c53f37b00646e25800832816a3f12de666882b939851b58de082c39ad33c93af",
    "child-policy.mjs": "39db0dc3cb888fc7e1c3f8ed8400291d4dc3c7bfecad7bb99297f7b480daf0f8",
    "mcp-client-entry.mjs": "0a2ffbdb963153a9312ebfb1f0961e076e7e468046987a2cd9a316ca64880543",
    "mcp-client-sdk.mjs": "73661e63c24791d33221730cb7cb7a738b0d347b379452dabebda35b1889d37c",
    "mcp-client.bundle.cjs": "145a34f19b020229b53c8ab89ab7970b7e4cffb9e3f09e2bda9a6c589b8457f1",
    "package.json": "21d6f0599cbbf59569e2faf17b0fd8aaf68044501ad794eb33eb298ca223d1ab",
    "package-lock.json": "a179cd7e5e477a5d48a88120b482799671c6f81884dce469914622c93e98e02b",
  ]
}
