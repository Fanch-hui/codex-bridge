# ZCode API

- Upstream: https://github.com/TriDefender/zcode-api
- Revision: `158e7653b738cbed0996243eeabd26f816638e81`
- Version: `4.8.8.android`
- License: CC-BY-NC-SA-4.0, reproduced in `LICENSE`.

The DSH integration uses the upstream proxy, authentication, quota, and
protocol implementation. Its model-verification path honors the server's
`skip_model_request` setting and reports when verification is required. The
verification config request uses the actual operating system and CPU
architecture. The quota route obtains credentials from the active
authentication manager, and accepts a separately bounded control-plane fetch;
an empty billing or preview response is reported as a quota-plane error.
