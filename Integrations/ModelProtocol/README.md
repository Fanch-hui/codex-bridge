# Model protocol conversion

This helper converts OpenAI Chat Completions, OpenAI Responses and Anthropic
Messages requests and SSE responses. It has no listener, provider credentials,
account management or routing. The caller owns upstream I/O and cancellation.

The protocol implementation is extracted from
[Magpie](https://github.com/yetone/magpie) at commit
`f9492fd8ed2c6fd3c65f1dab00062771b551d7b5`, under the accompanying MIT
license. The extraction keeps declarations used by these protocols and removes
two fields belonging to Magpie's subscription runtime. The signature-cache
directory is provided by Bridge instead of Magpie's configuration directory;
two provider diagnostics use product-neutral wording. The extraction also
preserves strict tool settings and structured-output semantics across protocols,
and retains tool schemas as supplied. Bridge-owned identifiers, comments, the
fallback search tool name and the Claude reasoning seal prefix use neutral
names; seals with the upstream prefix remain readable. Plugin-facing JSON
fields keep their upstream names.

## Build

Go 1.26.8 or later is required. Build one of the six desktop targets with:

```sh
tools/build.sh darwin arm64 /absolute/path/model-protocol
```

The script accepts `darwin`, `windows` or `linux`, and `amd64` or `arm64`.
On Windows, `tools/build.ps1 -TargetOS windows -TargetArch amd64 -Output <path>`
provides the same build. Set `GO` to select a Go executable. Run checks with
`go test -mod=readonly ./...`.

To reproduce the vendored declarations, download the commit's source archive
from `https://github.com/yetone/magpie/archive/f9492fd8ed2c6fd3c65f1dab00062771b551d7b5.tar.gz`,
then run `tools/extract.sh <archive> <empty-output-directory>`. Compare the
output's `internal` tree to this module, excluding `bridge_protocol*.go`,
which contains Bridge's RPC integration and its tests, and accounting for the
tool and output handling described above.

## JSONL protocol

Start the program with `--state-dir <absolute-private-directory>`. The directory
is used for opaque reasoning/signature carry-over; it must belong to Bridge and
must not be shared with another instance. Each input and output is one JSON
line. Requests have `{ "id": ..., "method": "...", "params": {...} }`;
responses have the same `id` and either `result` or `error: {code, message}`.

| Method | Parameters | Result |
| --- | --- | --- |
| `translateRequest` | `requestId`, `from`, `to`, `model`, `host`, `body`, `plugin` | `body`, `stream` |
| `startResponse` | `requestId` | Empty object |
| `responseChunk` | `requestId`, base64 `data` | Base64 `data`, boolean `failed` |
| `finishResponse` | `requestId` | Base64 `data` |
| `cancel` | `requestId` | Boolean `cancelled` |

`from` and `to` are `chat`, `responses` or `anthropic`; the caller handles
same-protocol passthrough. `body` is a JSON string, `model` is the upstream model
ID, `host` is its hostname, and `plugin` selects the upstream's Chat decoder
behavior. The translated upstream request always asks for SSE; `stream` in the
result is the original client's preference. Non-streaming client replies are
collected until `finishResponse`.

For each ID, call `translateRequest`, `startResponse`, zero or more
`responseChunk` calls, then `finishResponse` or `cancel` in order. Chunks are
arbitrary byte boundaries and results may be empty. IDs may be interleaved.
The helper requires a real upstream terminal event and returns
`incomplete_stream` on premature EOF. If a chunk returns `failed`, forward any
returned error event, stop the upstream request and do not emit a successful
completion. The caller must invoke `cancel` after abandoning any request and
must close the actual upstream request when cancellation is requested.
