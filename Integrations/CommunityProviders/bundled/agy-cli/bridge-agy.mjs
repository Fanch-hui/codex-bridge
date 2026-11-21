// Codex Bridge: the agy CLI is installed and updated from Codex Bridge's
// Connections page (or by the user), never by this plugin. Upstream downloads
// agy when it is missing (install.mjs, run from auth.cli.install) and
// refreshes its own copy every six hours (keepAgyCurrent); this build ships
// without install.mjs, and says so here instead.

// What a person does about a missing agy. The host shows it as the manual
// step, so it stays short. minVersion is index.mjs's MIN_AGY_VERSION.
export function agySetupHint(minVersion) {
  return `Codex Bridge does not download or update agy. Set it up in Codex Bridge under 连接 → Antigravity ` +
    `(Connections → Antigravity), or install agy ${minVersion} or newer yourself (1.5.0 or newer for image input).`
}

// auth.cli.install: there is nothing to install from here.
export function agyInstallDisabledError(minVersion) {
  return new Error(`agy CLI not found. ${agySetupHint(minVersion)}`)
}

// The model address the plugin reports. Upstream says "agy://local", which the
// Codex Bridge host and model gateway refuse as not http(s), so every model
// was listed as unavailable. The plugin's own fetch serves each request, so
// this address is never dialled; ".invalid" never resolves should it be.
export const AGY_PLACEHOLDER_URL = "http://agy.invalid"
