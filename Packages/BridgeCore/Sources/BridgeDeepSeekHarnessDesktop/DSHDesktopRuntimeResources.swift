import BridgeSecurity
import Crypto
import Foundation

public enum DSHDesktopRuntimeResources {
  public static let expectedDigests: [String: String] = [
    "client.js": "0fd454ad94dd8fff9f620194ae0faee3c9820d29c2e9a2cb80e4a9ce9e3fc6fe",
    "connector.mjs": "4832c6d373f33e325b1bf0d7a8db7d1a7ada3592348dcd082fc1a9185480896c",
    "cordis.patch.yml": "f7c67c2ac62cc239943a304acace76340cbcb7da843591af1a8678257e1a06af",
    "errors.mjs": "02c837f0a83d4d709d50bf13613ff451768692226f1da631af8714b55847d6bf",
    "event-mapping.mjs": "31f113cb63a4cd4cf7855f88a6ce050bbcc6022a5ac351b8d6dc7685ddbeb143",
    "history.mjs": "b3d599a4692bc277c99e250c684aa80ecbc5a47c407626627191b78cfc750007",
    "host-version.mjs": "49c72bfd8c24a7809c365382817b7c49b985a10bbdf6675c7bc3494072c1fe6f",
    "index.mjs": "ed634199580283960fe51649eb26adc7145836e3cb340a82f45301f94ce4429c",
    "interactions.mjs": "2dd09c21854376e1a3ea58c8167d02e690f5683a3c76fe64bffbefc49a399938",
    "models.mjs": "adc8dcdc60a69b2d2c5cfadc7dfde1a42fab70722bf5d8c9a6c7868aa56ae58e",
    "native-services.mjs": "94f8f611136622cafda174d09360f3f663f55c63b55b08dc58ec07295516a44f",
    "package.json": "b713b6ef4aaf57fa76c36ddaf8af0f9d24d9cc7afdbad9fb3a4c75740c2c18a2",
    "pairing.mjs": "fce6f74cfd9bc9e22666203d296877040eaf34f870234759ef9a1fa2ea869d65",
    "project-grants.mjs": "8a0005aabba2506a723c86ce2cefa6582b15f96ae395f77ad22161845b036a87",
    "progress.mjs": "f595d2501decf58927a21b14efc20a11289f2a26dc968e292e5ea55c2c60ddfd",
    "protocol.mjs": "79a2232644aaf3c4719559288566f9c468b0ff1189d0a2c394f0d3321d693b14",
    "run-store.mjs": "0ed133151ac80f34f25e36a1979e46c72a3beadd3bf30b15f8ecf9a556cbb678",
    "runs.mjs": "bf963797d16d403925e9abe17003d823b46ab9f1d9e6b3f881344b8c91346be1",
    "transport.mjs": "539f659754e1095cd3f93fe978525ab20991b5e4cc1fe853af8fc22d5699f276",
    "ui-channel.mjs": "746a37b93bb5c9c54057954873f4731a6568fbd5be6e9ea0afa3948c4b306ee3",
  ]

  public static var fingerprint: String {
    let value = expectedDigests.keys.sorted().map { "\($0):\(expectedDigests[$0]!)" }.joined(
      separator: "\n")
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public static func validatedDirectory(directory: URL? = nil) throws -> URL {
    guard
      let root = directory
        ?? Bundle.module.resourceURL?.appendingPathComponent("DSHDesktopConnector")
    else {
      throw SecureFileArtifactError.openFailed
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    guard Set(names) == Set(expectedDigests.keys) else {
      throw SecureFileArtifactError.invalidDigest
    }
    for (name, digest) in expectedDigests {
      let file = root.appendingPathComponent(name)
      let snapshot = try SecureFileArtifactSnapshot.capture(
        at: file.path, maximumBytes: 4 * 1_024 * 1_024)
      guard snapshot.sha256 == digest else { throw SecureFileArtifactError.invalidDigest }
    }
    return root
  }
}
