# Third-party sources and notices

## zcode-api

- Repository: https://github.com/TriDefender/zcode-api
- Author: TriDefender and upstream contributors.
- Reference commit: `158e7653b738cbed0996243eeabd26f816638e81` (`4.8.8.android`).
- License: CC BY-NC-SA 4.0, preserved in `vendor/zcode-api/LICENSE`.
- Source: `vendor/zcode-api`. The proxy bundle directly includes upstream authentication, configuration, request transformation, transport, protocol handling, and quota modules.
- Integration source: `integration`, built by `scripts/build-proxy.mjs`. These adaptations of the proxy are distributed under CC-BY-NC-SA-4.0.
- Integration changes: private IPC lifecycle and in-memory DSH credentials; loopback binding with a random port and temporary API key; model-request verification policy support and required-verification errors; disabled optional claim, MCP, Responses, and async features.
- Bundled dependency licenses: `lib/proxy/THIRD_PARTY_LICENSES.txt`.

The source snapshot and integration source accompany the package. Attribution and share-alike terms for the proxy component apply to its redistribution and modification.

## DeepSeek Harness

- Repository: https://github.com/deepseek-ai/deepseek-harness
- Reference release: `dsh-v0.2.2-rc.1` (`66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db`).
- Compatibility baseline: `dsh-v0.2.2-alpha.3` (`05b1cae8db6e674c5685101494d4eec24652424a`).
- License: MIT. Host and browser shared packages are provided by DSH. The standalone CLI bundles the required credential service runtime; its dependency licenses are in `lib/cli/THIRD_PARTY_LICENSES.txt`.
- Contracts: `LlmAdapter`, stream chunks, replay envelopes, credentials, volatile configuration, Typert RPC, and browser plugin factories.

## ZCode model catalog

- Repository: https://github.com/zai-org/ZCode
- Reference commit: `a9fe401eede6e6e5e01be9048679c206fe6f02d9` (v3.17.2).
- License: Apache-2.0.
- Reference: `config/provider/zcode-builtin.json`, revision 43, for DSH model capability declarations.

## DSH adapter and runtime dependencies

The DSH adapter source in `src` is licensed under Apache-2.0. Undici and Zod retain their MIT licenses; YAML retains its ISC license. Their packages include the respective license files. Development tools retain their upstream licenses.
