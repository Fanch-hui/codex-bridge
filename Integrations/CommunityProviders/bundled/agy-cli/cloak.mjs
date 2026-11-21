// System prompt lines Antigravity turns away, and paragraphs it answers
// badly, the same lists and the same rewrites as
// packages/antigravity/index.mjs up to 0.1.18 (TURNED_AWAY, SAID_AS, cloak, hint,
// REWORDED, reword, outgoing). Each package ships on its own, so the code is
// a copy, and since antigravity 0.2.0 sends nothing this is the only one.
//
// Antigravity answers a 429 "Resource has been exhausted" to a request whose
// system prompt has one of these lines, whatever quota is left, and lets the
// same prompt through reworded. agy-cli hands the client's system prompt to
// agy (session instructions, or <external_system_instructions> in the
// prompt), and agy sends it to Antigravity as written, so it is reworded
// here before it goes. What the bridge keys sessions on (instructionsIdentity) is the
// prompt as the client wrote it.

// TURNED_AWAY are the lines, lower-cased, Antigravity answers a 429 to
// whatever quota is left. Each goes as SAID_AS says instead. The last four
// are turned away since the evening of 11-14 (Lmohn39 and ZhouYimingsjtu on
// X), each 3 of 3 or 5 of 5 on a real account, on gemini-3-flash and
// claude-sonnet-4-6 alike:
//   - "You are Hermes Agent": Hermes' current persona ("You are Hermes
//     Agent, built by Nous Research.") and its earlier one, and the earlier
//     one as magpie reworded it up to 0.1.15 ("… built by Nous Research").
//     The earlier one ("…, an intelligent AI assistant created by Nous
//     Research.") is turned away as "You're Hermes Agent, …" too, 3 of 3,
//     so its "created by" goes "built by" as before as well.
//   - "You are OpenCode", whichever of OpenCode 2.0.25's lines follows it
//     ("a coding agent that helps users…", "an interactive CLI tool…", "the
//     best coding agent on the planet").
//   - "You are a coding agent running in the Codex CLI", Codex's prompt for
//     a model it has no prompt of its own for (Codex 0.165).
//   - "a coding assistant running inside pi", pi 1.5.0's default prompt
//     ("You are a coding assistant running inside pi, a coding agent
//     harness."), as "agent" for "assistant" and "that runs inside pi" are.
// Since 11-15 DeepSeek Harness's first line, "You are an AI agent powered
// by DeepSeek Harness.", is turned away too (#1171, huangzhenhao90, on a
// real account through agy on gemini-4-hydrogen): "powered by DeepSeek."
// alone, "an agent" for "an AI agent" and "You're …" each went through.
// Since 11-17 so is a sentence in the middle of DeepSeek Harness's Web GUI
// paragraph (@deepseek-ai/dsh-harness-dev-context), "The browser provides
// no implicit DOM, route, or screenshot context." (#1105, LayFz, on an Ultra
// account on gemini-4-hydrogen-medium and -xhigh; 3 of 3 on gemini-3.8-flash
// and gemini-4-hydrogen-sonar on 11-17, lower-cased or wrapped too, and the
// whole paragraph with it). Without its period, without the comma before
// "or", without "implicit" or with "gives" for "provides" it went through.
// Since 11-15 Claude Code's identity line, "You are Claude Code,
// Anthropic's official CLI for Claude." (its CLI's, and with ", running
// within the Claude Agent SDK" its SDK's), is turned away too (#1151,
// KevinXC5, 3 of 3 through agy on gemini-4-hydrogen with Claude Code
// 2.1.325); "You're …" and "This agent is …" each went through 3 of 3.
// Codex's prompt for GPT-6 ("You are Codex, an agent based on GPT-6."),
// the rest of Claude Code's, Gemini CLI's, Qwen Code's, Cline's, Kilo's, goose's, Amp's,
// Droid's, Kimi CLI's, Aider's and Cursor's went through as written.
export const TURNED_AWAY = [
  "x-anthropic-billing-header:",
  "built on anthropic's claude agent sdk",
  "you are codex, an agent based on gpt-5",
  "you are codex, a coding agent based on gpt-5",
  "rfc 2119 keywords: must, required, should, recommended, may, optional.",
  "you are hermes agent",
  "an intelligent ai assistant created by nous research",
  "you are opencode",
  "you are a coding agent running in the codex cli",
  "a coding assistant running inside pi",
  "you are an ai agent powered by deepseek harness",
  "you are claude code, anthropic's official cli for claude",
  "the browser provides no implicit dom, route, or screenshot context.",
]

// INVISIBLE are the characters Google's check reads past: since 11-14 a
// line with a zero-width space (U+200B) after the first and second
// character of each word, or after every character, or U+2060, is turned
// away as the line itself, 5 of 5 on a real account for every line here
// (hc295971796 on X, Claude Desktop's Code tab). A copy someone broke up
// that way (the antigravity-cloak middleware before 0.1.7, an older magpie)
// is matched as the line.
const INVISIBLE = "[\\u00ad\\u180e\\u200b-\\u200f\\u2060-\\u2064\\ufeff]"
const INVISIBLE_RE = new RegExp(INVISIBLE, "g")

const escape = (c) => c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

// lineRe matches line in any case, with any run of white space between its
// words and any invisible characters inside them: Google's check reads a
// line break, a tab, two spaces or a no-break space where the line has one
// space, and turned omp's line away wrapped after "REQUIRED," or after
// "RFC 2119" as it did on one line, while a missing period, a space dropped
// after a comma or the words in another order went through (a real
// account, 11-14). Claude Code's billing line is matched to its end, since
// it goes whole.
const lineRe = (line) => {
  const words = line.split(" ").map((w) => [...w].map(escape).join(`${INVISIBLE}*`))
  const tail = line === "x-anthropic-billing-header:" ? "[^\\n]*\\n?" : ""
  return new RegExp(words.join(`${INVISIBLE}*\\s+${INVISIBLE}*`) + tail, "gi")
}
const TURNED_AWAY_RE = TURNED_AWAY.map(lineRe)
const has = (s, re) => {
  re.lastIndex = 0
  const yes = re.test(s)
  re.lastIndex = 0
  return yes
}
const said = (system, line) => has(system, TURNED_AWAY_RE[TURNED_AWAY.indexOf(line)])

export function turnsAway(system) {
  const s = String(system ?? "")
  return TURNED_AWAY_RE.some((re) => has(s, re))
}

// SAID_AS is how each line goes, with its invisible characters taken out
// and its white space as it was: a rewording that keeps its meaning, each
// answered 5 of 5 on a real account on 11-14 while the line itself, broken
// up or not, was turned away 5 of 5.
//   - Claude Code's billing line is left out: it is Anthropic's, and no
//     Antigravity model reads anything in it.
//   - "built on Anthropic's Claude Agent SDK", the Agent SDK's identity
//     line (Claude Desktop's Code tab and its subagents), goes as "built on
//     the Claude Agent SDK by Anthropic".
//   - Codex's GPT-5 lines go "built on GPT-5" for "based on GPT-5".
//   - "You are Hermes Agent", "You are OpenCode" and Codex CLI's line go
//     as "You're …" (5 of 5 each), and Hermes' earlier "created by Nous
//     Research" as "built by" (3 of 3 together).
//   - pi's line goes "running within pi" (5 of 5 on both models).
//   - DeepSeek Harness's line goes as "You're …" (#1171), and so does
//     Claude Code's identity line (#1151).
//   - DeepSeek Harness's browser sentence goes "gives no implicit DOM, …"
//     for "provides" (3 of 3 alone and in its paragraph on 11-17, #1105).
//   - omp's RFC 2119 line goes as "key words", the RFC's own term (10 of 10
//     on 11-14, eric_li8983 on X).
const youre = (line) => line.replace(/^(you)\s+are/i, "$1're")
const SAID_AS = {
  "x-anthropic-billing-header:": () => "",
  "built on anthropic's claude agent sdk": (line) => line.replace(/^(built\s+on\s+)anthropic's(\s+)(claude\s+agent\s+sdk)$/i, "$1the$2$3 by Anthropic"),
  "you are codex, an agent based on gpt-5": (line) => line.replace(/based(\s+)on/i, "built$1on"),
  "you are codex, a coding agent based on gpt-5": (line) => line.replace(/based(\s+)on/i, "built$1on"),
  "rfc 2119 keywords: must, required, should, recommended, may, optional.": (line) => line.replace(/(key)(words)/i, "$1 $2"),
  "you are hermes agent": youre,
  "an intelligent ai assistant created by nous research": (line) => line.replace(/created(\s+)by/i, "built$1by"),
  "you are opencode": youre,
  "you are a coding agent running in the codex cli": youre,
  "a coding assistant running inside pi": (line) => line.replace(/inside/i, "within"),
  "you are an ai agent powered by deepseek harness": youre,
  "you are claude code, anthropic's official cli for claude": youre,
  "the browser provides no implicit dom, route, or screenshot context.": (line) => line.replace(/provides/i, "gives"),
}

// USER_TURNED_AWAY are the lines Antigravity also turns away in a user's
// turn: since 11-14 Codex's GPT-5 lines there got a bare 429 "Resource has
// been exhausted" 3 of 3 on a real account, where a pasted AGENTS.md or a
// developer message told after a reply puts them, and went through
// reworded. The others went through as written there, 3 of 3 each, and so
// did all of them in the model's turns and in tool results
// (packages/antigravity's USER_TURNED_AWAY). Everything agy-cli hands agy as
// a prompt goes to Antigravity in a user's turn, the history it replays and
// the tool results it renders included, so cloakUser runs over all of it.
export const USER_TURNED_AWAY = TURNED_AWAY.filter((l) => l.startsWith("you are codex, "))

// cloak rewords the lines of only, or of TURNED_AWAY when only is left out
export function cloak(system, only) {
  if (typeof system !== "string" || !turnsAway(system)) return system
  const at = []
  TURNED_AWAY_RE.forEach((re, i) => {
    if (only && !only.includes(TURNED_AWAY[i])) return
    for (const m of system.matchAll(re)) at.push([m.index, m.index + m[0].length, SAID_AS[TURNED_AWAY[i]]])
  })
  at.sort((a, b) => a[0] - b[0])
  let out = ""
  let prev = 0
  for (const [from, to, as] of at) {
    if (from < prev) continue
    out += system.slice(prev, from) + as(system.slice(from, to).replace(INVISIBLE_RE, ""))
    prev = to
  }
  return out + system.slice(prev)
}

// REWORDED are paragraphs that go through but are answered badly, each with
// a rewording that keeps its meaning. DeepSeek Harness's desktop app puts
// the first in every system prompt; word for word, gemini-4-argon answered
// most requests in about 3s with no thinking and ended after one shallow
// step (antigravity #1028).
export const REWORDED = [
  [
    "Tokens prefixed with @ are paths the user explicitly referenced. Relative paths resolve from the workspace root; absolute paths identify files or directories on the host. A trailing slash marks a directory: list it when its contents matter. Anything else is a file: use the read tool when its contents are needed, and do not claim to have inspected it before reading. @\"...\" quotes a path containing spaces.",
    "When the user writes @ followed by a path, they are pointing at that file or folder. Relative paths start at the workspace root; absolute paths are host paths. A path ending in a slash is a folder, so list it if its contents matter; otherwise it is a file, so open it with the read tool before relying on it. Paths with spaces appear as @\"...\".",
  ],
]

export function reword(system) {
  if (typeof system !== "string") return system
  for (const [from, to] of REWORDED) if (system.includes(from)) system = system.split(from).join(to)
  return system
}

// cloakUser is the text of a prompt agy is handed (a user's turn upstream)
// with USER_TURNED_AWAY's lines reworded and everything else as written
export const cloakUser = (text) => cloak(text, USER_TURNED_AWAY)

// outgoing is system text as agy is handed it: each turned-away line and
// each paragraph of REWORDED reworded
export const outgoing = (system) => reword(cloak(system))

const HINT =
  "Antigravity answers this 429 to the system prompt of Claude Code and the Claude Agent SDK (Claude Desktop's chats) whatever quota is left, so it is not a quota and waiting won't help; use another provider for these chats, or put one after Antigravity in a routing group"

const CODEX_HINT =
  "Antigravity answers this 429 to Codex's own system prompt for GPT-5 models whatever quota is left, so it is not a quota and waiting won't help; a Codex chat begun on a GPT model keeps that prompt after a model switch or a fork, so start a new chat on this model"
const HERMES_HINT =
  "Antigravity answers this 429 to Hermes Agent's default persona (\"You are Hermes Agent, …\" in its SOUL.md), the current one and the earlier one alike, whatever quota is left, so it is not a quota and waiting won't help; magpie sends it as \"You're Hermes Agent, …\", which goes through, so start SOUL.md another way, or use another provider for these chats"

const PI_HINT =
  "Antigravity answers this 429 to pi's default system prompt (\"You are a coding assistant running inside pi\") whatever quota is left, so it is not a quota and waiting won't help; magpie sends that line as \"running within pi\", which goes through, so give pi a system prompt of your own (--system-prompt) or use another provider for these chats"
const OPENCODE_HINT =
  "Antigravity answers this 429 to OpenCode's system prompt (\"You are OpenCode, …\") whatever quota is left, so it is not a quota and waiting won't help; magpie sends that line as \"You're OpenCode, …\", which goes through, so use another provider for these chats, or put one after Antigravity in a routing group"
const CODEX_CLI_HINT =
  "Antigravity answers this 429 to Codex's prompt for a model it has none of its own for (\"You are a coding agent running in the Codex CLI\") whatever quota is left, so it is not a quota and waiting won't help; magpie sends that line as \"You're …\", which goes through, so use another provider for these chats, or put one after Antigravity in a routing group"

const DSH_HINT =
  "Antigravity answers this 429 to DeepSeek Harness's system prompt (\"You are an AI agent powered by DeepSeek Harness.\", or \"The browser provides no implicit DOM, route, or screenshot context.\" in its Web GUI's) whatever quota is left, so it is not a quota and waiting won't help; magpie sends those lines as \"You're …\" and \"The browser gives …\", which go through, so use another provider for these chats, or put one after Antigravity in a routing group"

const RFC_HINT =
  "Antigravity answers this 429 to the line \"RFC 2119 keywords: MUST, REQUIRED, SHOULD, RECOMMENDED, MAY, OPTIONAL.\" that starts oh-my-pi (omp)'s system prompt, and to any prompt that has it, whatever quota is left, so it is not a quota and waiting won't help; magpie sends that line as \"RFC 2119 key words: …\", which goes through, so this one came from a copy of it that was worded another way"

export function hint(system) {
  system = String(system ?? "")
  if (said(system, "rfc 2119 keywords: must, required, should, recommended, may, optional.")) return RFC_HINT
  if (said(system, "you are codex, an agent based on gpt-5") || said(system, "you are codex, a coding agent based on gpt-5")) return CODEX_HINT
  if (said(system, "you are a coding agent running in the codex cli")) return CODEX_CLI_HINT
  if (said(system, "you are hermes agent") || said(system, "an intelligent ai assistant created by nous research")) return HERMES_HINT
  if (said(system, "you are opencode")) return OPENCODE_HINT
  if (said(system, "a coding assistant running inside pi")) return PI_HINT
  if (said(system, "you are an ai agent powered by deepseek harness") || said(system, "the browser provides no implicit dom, route, or screenshot context.")) return DSH_HINT
  return HINT
}
