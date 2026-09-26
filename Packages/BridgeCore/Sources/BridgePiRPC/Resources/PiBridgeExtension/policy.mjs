import { createHash } from "node:crypto";
import { lstat, realpath } from "node:fs/promises";
import path from "node:path";

export const approvalPrefix = "codex-bridge.pi.approval.v1:";
export const approvalOptions = Object.freeze(["allow_once", "allow_for_session", "deny"]);
const readable = new Set(["read", "grep", "find", "ls"]);
const writable = new Set(["write", "edit"]);
const shells = new Set(["bash", "powershell"]);
const managedTools = new Set(["bridge_plan", "bridge_ask_user", "bridge_subtask"]);
const permissionEffects = new Set(["allow", "ask", "deny"]);
const blockedComponents = new Set([".git", ".ssh", ".aws", "secrets", "node_modules"]);

export function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}

export function digest(value) {
  return createHash("sha256").update(JSON.stringify(canonical(value))).digest("hex");
}

export function validateContext(value) {
  if (!value || value.revision !== 1 || typeof value.nonce !== "string"
      || !/^[a-z0-9-]{36}$/.test(value.nonce) || !path.isAbsolute(value.projectRoot ?? "")
      || !["read-only", "workspace-write"].includes(value.mode)
      || typeof value.networkAllowed !== "boolean" || typeof value.taskID !== "string"
      || value.taskID.length > 128 || !Array.isArray(value.tools) || value.tools.length > 16) {
    throw new Error("Invalid Bridge Pi execution context.");
  }
  if (!Array.isArray(value.cliArgv) || value.cliArgv.length < 1 || value.cliArgv.length > 2
      || value.cliArgv.some(item => typeof item !== "string" || !item || item.includes("\0"))) {
    throw new Error("Invalid Bridge Pi CLI invocation.");
  }
  const skillPaths = value.skillPaths ?? [];
  if (!Array.isArray(skillPaths) || skillPaths.length > 16
      || skillPaths.some(item => typeof item !== "string" || !path.isAbsolute(item)
        || item.includes("\0") || Buffer.byteLength(item) > 4096)) {
    throw new Error("Invalid Bridge Pi skill paths.");
  }
  const allowed = new Set([...readable, ...writable, ...shells, ...managedTools]);
  if (new Set(value.tools).size !== value.tools.length || value.tools.some(name => !allowed.has(name))) {
    throw new Error("Invalid Bridge Pi tool selection.");
  }
  const nativePermissionRules = value.nativePermissionRules ?? [];
  if (!Array.isArray(nativePermissionRules) || nativePermissionRules.length > 1536
      || nativePermissionRules.some(rule => !validPermissionRule(rule))) {
    throw new Error("Invalid Bridge Pi permission rules.");
  }
  const mcpServers = value.mcpServers ?? [];
  if (!Array.isArray(mcpServers) || mcpServers.length > 64
      || mcpServers.some(server => !validMCPServer(server))) {
    throw new Error("Invalid Bridge Pi MCP configuration.");
  }
  return Object.freeze({ ...value, tools: Object.freeze([...value.tools]),
    skillPaths: Object.freeze([...skillPaths]),
    nativePermissionRules: Object.freeze([...nativePermissionRules]),
    mcpServers: Object.freeze([...mcpServers]) });
}

function validPermissionRule(rule) {
  return Boolean(rule && permissionEffects.has(rule.effect)
    && ["read", "grep", "find", "ls", "write", "edit", "bash", "powershell"].includes(rule.action)
    && typeof rule.target === "string" && rule.target.length > 0
    && Buffer.byteLength(rule.target) <= 4096 && !rule.target.includes("\0"));
}

function validMCPServer(server) {
  if (!(server && typeof server === "object"
    && typeof server.id === "string" && server.id.length > 0 && server.id.length <= 256
    && typeof server.name === "string" && server.name.length > 0 && server.name.length <= 256
    && ["stdio", "http"].includes(server.transport)
    && (server.command === null || typeof server.command === "string")
    && Array.isArray(server.args) && server.args.length <= 128
    && server.args.every(value => typeof value === "string")
    && (server.url === null || typeof server.url === "string")
    && validStringMap(server.environment) && validStringMap(server.headers))) return false;
  if (server.transport === "stdio") {
    return typeof server.command === "string" && server.command.length > 0 && server.url === null;
  }
  try {
    const url = new URL(server.url);
    return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password
      && server.command === null && server.args.length === 0
      && Object.entries(server.headers).every(([key, value]) => /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(key)
        && !/[\r\n\0]/.test(value));
  } catch { return false; }
}

function validStringMap(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value)
    && Object.keys(value).length <= 128
    && Object.entries(value).every(([key, item]) => key.length > 0 && key.length <= 256
      && typeof item === "string" && Buffer.byteLength(item) <= 8192
      && !key.includes("\0") && !item.includes("\0")));
}

export function isContained(root, target, style = path) {
  const relative = style.relative(root, target);
  return relative === "" || (!style.isAbsolute(relative) && relative !== ".."
    && !relative.startsWith(".." + style.sep));
}

async function checkedPath(root, input, allowMissing) {
  if (typeof input !== "string" || input.includes("\0") || Buffer.byteLength(input) > 16384) {
    throw new Error("Invalid tool path.");
  }
  const target = path.resolve(root, input);
  if (!isContained(root, target)) throw new Error("Path is outside the approved project.");
  const relative = path.relative(root, target);
  const components = relative ? relative.split(path.sep) : [];
  if (components.some(part => blockedComponents.has(part.toLowerCase()) || /^\.env(?:\.|$)/i.test(part))) {
    throw new Error("Sensitive or dependency paths are not available to this tool.");
  }
  let cursor = root;
  for (const component of components) {
    cursor = path.join(cursor, component);
    try {
      const metadata = await lstat(cursor);
      if (metadata.isSymbolicLink()) throw new Error("Linked paths require a separately approved workspace.");
    } catch (error) {
      if (allowMissing && error?.code === "ENOENT") break;
      throw error;
    }
  }
  return relative.split(path.sep).join("/");
}

export function createPolicy(context) {
  const config = validateContext(context);
  const approvals = new Set();
  const mcpTools = new Map();

  function permissionEffect(action, target) {
    const normalized = action === "bash" || action === "powershell"
      ? target : target.replaceAll("\\", "/");
    const matching = config.nativePermissionRules.filter(rule => rule.action === action
      && matchesGlob(rule.target, normalized));
    if (matching.some(rule => rule.effect === "deny")) return "deny";
    if (matching.some(rule => rule.effect === "ask")) return "ask";
    if (matching.some(rule => rule.effect === "allow")) return "allow";
    return undefined;
  }

  async function inspect(event) {
    if (!event || (!config.tools.includes(event.toolName) && !mcpTools.has(event.toolName))
        || typeof event.toolCallId !== "string"
        || event.toolCallId.length > 200 || !event.input || typeof event.input !== "object") {
      throw new Error("Tool is not in the active task policy.");
    }
    const root = await realpath(config.projectRoot);
    if (!isContained(config.projectRoot, root) || !isContained(root, config.projectRoot)) {
      throw new Error("Project identity changed.");
    }
    const payloadDigest = digest({ tool: event.toolName, input: event.input });
    const envelope = { revision: 1, nonce: config.nonce, taskID: config.taskID,
      toolCallID: event.toolCallId, tool: event.toolName, payloadDigest, relativePaths: [] };
    if (managedTools.has(event.toolName)) return { allowed: true, envelope };
    const mcpTool = mcpTools.get(event.toolName);
    if (mcpTool) {
      if (config.mode !== "workspace-write" || !config.networkAllowed) {
        return { allowed: false, denied: true,
          reason: "Configured MCP tools require explicit network access in Write mode." };
      }
      if (Buffer.byteLength(JSON.stringify(event.input)) > 32 * 1_024) {
        return { allowed: false, denied: true, reason: "MCP tool arguments exceed the task limit." };
      }
      envelope.tool = `MCP ${mcpTool.serverName} / ${mcpTool.toolName}`;
      envelope.approvalKind = "network";
      envelope.networkTarget = `${mcpTool.serverName} / ${mcpTool.toolName}`;
      return { allowed: approvals.has(payloadDigest), envelope };
    }
    if (shells.has(event.toolName)) {
      if (config.mode !== "workspace-write" || !config.networkAllowed) {
        throw new Error("Shell tools require Write mode and explicit network-capable execution.");
      }
      const command = event.input.command;
      if (typeof command !== "string" || !command.trim() || command.includes("\0")
          || Buffer.byteLength(command) > 8192) throw new Error("Invalid shell command.");
      envelope.command = command;
      const effect = permissionEffect(event.toolName, command);
      if (effect === "deny") return { allowed: false, denied: true, reason: "A saved Pi permission rule denied this command." };
      if (effect === "allow") return { allowed: true, envelope };
      if (effect === "ask" && !approvals.has(payloadDigest)) return { allowed: false, envelope };
      if (effect === "ask") return { allowed: true, envelope };
      return { allowed: approvals.has(payloadDigest), envelope };
    }
    if (!readable.has(event.toolName) && !writable.has(event.toolName)) {
      throw new Error("Unsupported tool.");
    }
    const writing = writable.has(event.toolName);
    if (writing && config.mode !== "workspace-write") throw new Error("The task is read-only.");
    const relative = await checkedPath(root, event.input.path ?? (writing ? "" : "."), event.toolName === "write");
    if (writing && !relative) throw new Error("A file path is required.");
    if (relative) envelope.relativePaths.push(relative);
    const effect = permissionEffect(event.toolName, relative || ".");
    if (effect === "deny") return { allowed: false, denied: true, reason: "A saved Pi permission rule denied this path." };
    if (effect === "allow") return { allowed: true, envelope };
    if (effect === "ask" && !approvals.has(payloadDigest)) return { allowed: false, envelope };
    if (effect === "ask") return { allowed: true, envelope };
    return { allowed: !writing || approvals.has(payloadDigest), envelope };
  }

  function decide(envelope, option) {
    if (option === "allow_for_session") {
      if (approvals.size >= 256) return false;
      approvals.add(envelope.payloadDigest);
    }
    return option === "allow_once" || option === "allow_for_session";
  }

  function registerMCPTool(name, serverID, serverName, toolName) {
    if (typeof name !== "string" || !/^bridge_mcp_[a-f0-9]{12}_[a-z0-9_-]{1,28}_[a-f0-9]{10}$/.test(name)
        || !config.mcpServers.some(server => server.id === serverID)
        || typeof serverName !== "string" || !serverName.trim()
        || typeof toolName !== "string" || !toolName.trim()
        || mcpTools.size >= 128 || config.tools.includes(name) || mcpTools.has(name)) return false;
    mcpTools.set(name, { serverID, serverName: serverName.slice(0, 256), toolName: toolName.slice(0, 256) });
    return true;
  }

  function unregisterMCPTool(name) { mcpTools.delete(name); }

  function activeToolNames() { return [...config.tools, ...[...mcpTools.keys()].sort()]; }

  return {
    inspect, decide, clear: () => approvals.clear(), registerMCPTool,
    unregisterMCPTool, activeToolNames, context: config,
  };
}

export function createReadOnlyChildPolicy(context) {
  const config = validateReadOnlyChildContext(context);

  async function inspect(event) {
    if (!event || !readable.has(event.toolName) || typeof event.toolCallId !== "string"
        || event.toolCallId.length > 200 || !event.input || typeof event.input !== "object") {
      return false;
    }
    const input = event.input.path ?? ".";
    const root = await rootForInput(input, config.roots, config.projectRoot);
    const relative = await checkedPath(root, input, false);
    const absolute = path.resolve(root, input);
    if (isDenied(event.toolName, [relative, absolute], config.nativePermissionRules)) return false;
    return true;
  }

  return Object.freeze({ inspect });
}

function validateReadOnlyChildContext(value) {
  if (!value || value.revision !== 1 || !path.isAbsolute(value.projectRoot ?? "")
      || !Array.isArray(value.skillPaths) || value.skillPaths.length > 16
      || value.skillPaths.some(item => typeof item !== "string" || !path.isAbsolute(item)
        || item.includes("\0") || Buffer.byteLength(item) > 4096)) {
    throw new Error("Invalid Bridge Pi child policy context.");
  }
  const nativePermissionRules = value.nativePermissionRules ?? [];
  if (!Array.isArray(nativePermissionRules) || nativePermissionRules.length > 1536
      || nativePermissionRules.some(rule => !validPermissionRule(rule))) {
    throw new Error("Invalid Bridge Pi child permission rules.");
  }
  return Object.freeze({
    projectRoot: value.projectRoot,
    roots: Object.freeze([value.projectRoot, ...value.skillPaths]),
    nativePermissionRules: Object.freeze([...nativePermissionRules]),
  });
}

async function rootForInput(input, roots, projectRoot) {
  const target = path.resolve(projectRoot, input);
  const root = path.isAbsolute(input)
    ? roots.find(candidate => isContained(candidate, target)) : projectRoot;
  if (!root) throw new Error("Path is outside the child task's read scope.");
  const actual = await realpath(root);
  if (!samePath(root, actual)) throw new Error("A child read root changed identity.");
  return actual;
}

function samePath(left, right) {
  return isContained(left, right) && isContained(right, left);
}

function isDenied(action, targets, rules) {
  return rules.some(rule => rule.action === action
    && ["deny", "ask"].includes(rule.effect)
    && targets.some(target => matchesGlob(rule.target, target)));
}

function matchesGlob(pattern, value) {
  const escaped = pattern.split("*").map(part => part.replace(/[|\\{}()[\]^$+?.]/g, "\\$&")).join(".*");
  const flags = process.platform === "win32" ? "i" : "";
  return new RegExp(`^${escaped}$`, flags).test(value);
}
