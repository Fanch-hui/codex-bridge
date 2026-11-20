# Community provider host

`vendor/magpie/host.js` is based on `internal/plugin/host.js` from
[Magpie commit f9492fd8ed2c6fd3c65f1dab00062771b551d7b5](https://github.com/yetone/magpie/tree/f9492fd8ed2c6fd3c65f1dab00062771b551d7b5),
under the MIT license in `vendor/magpie/LICENSE`. `bridge-secret.js` replaces
its credential-file storage with service-owned, provider-scoped RPC. The host
accepts provider operations only, selects header hooks for their owning plugin,
and acknowledges fetch cancellation after the request actually ends. Upstream's
stream credit protocol and request implementations remain in use. The service
must run only one host for an installation and wait for its exit before starting
a replacement; this is the renewal ownership boundary.

The host runs as `bun vendor/magpie/host.js`, with one JSON object per stdin or
stdout line. `init` accepts a private absolute `directory` and `plugins`, each
with `spec`, absolute installed `target`, and optional `options`. Available
operations are `providers`, `prompt`, `validate`, `authorize`, `callback`,
`apiKey`, `load`, `usage`, `check`, `signOut`, `reload`, `fetch`, `credit`, and
`abort`. Provider calls accept the upstream parameters; `providers` additionally
accepts an optional `provider` filter. Authentication callbacks use
`bridge/secret` requests with string IDs and `list`, `get`, or `commit`
operations. A `commit` is atomic within one provider. `load` can return an API
key and is intended only for the trusted service, never for an Agent or UI.

A fetch defaults to a 524288-byte window. Each `chunk` consumes its decoded
byte length plus 2048 bytes; the reader sends a matching `credit` after
consumption. `head` consumes no window credit. An `abort` for an active fetch
with its own ID replies after the fetch and stream cleanup finish. Active
non-fetch operations return an error when completion cannot be confirmed; the
service must terminate and await the host before releasing their ownership.

`catalog.json` records candidate npm packages and exact versions, not a
compatibility certification. `install.mjs` installs a version into its own
directory with Bun lifecycle scripts disabled; installing or loading a package
does not verify its authentication or live model requests. Third-party packages
run as local code. The service should treat plugin stderr as untrusted diagnostic
output that may contain credentials or request data.
