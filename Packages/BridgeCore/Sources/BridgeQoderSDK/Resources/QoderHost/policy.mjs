import { lstat, realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { requireValue, text, identifier, object, absolute, samePath, contained, digest, HostError } from './validation.mjs';

const reads = ['Read', 'Glob', 'Grep'];
const writes = ['Write', 'Edit', 'NotebookEdit'];
const plans = ['TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskList', 'UpdateGoal'];
const network = ['Bash', 'WebSearch', 'WebFetch'];
const subagents = ['Agent'];
const userInput = 'AskUserQuestion';
const blocked = new Set(['.git', '.ssh', '.aws', 'secrets']);

export function toolSelection(config) {
  const tools = [...reads, userInput, ...plans];
  if (config.mode === 'workspace-write') tools.push(...writes);
  if (config.networkAllowed && config.mode === 'workspace-write') tools.push(...network, ...subagents);
  if (config.skills?.length) tools.push('Skill');
  return tools;
}
export async function createPolicy(config, requestPermission, requestUserInput, { additionalReadRoots = [] } = {}) {
  const root = await realpath(absolute(config.cwd));
  const identity = await stat(root, { bigint: true });
  const readRoots = [
    { path: root, display: '' },
    ...await Promise.all(additionalReadRoots.map(async value => ({ path: await realpath(absolute(value)), display: '.selected-skills/' }))),
  ];
  const tools = new Set(toolSelection(config));
  const servers = new Set(Object.keys(config.mcpServers ?? {}));
  const sessionRules = new Set();
  const decisions = new Map();

  async function check(tool, input) {
    identifier(tool); object(input);
    const current = await stat(root, { bigint: true });
    requireValue(current.dev === identity.dev && current.ino === identity.ino, 'project_identity_changed');
    const mcp = [...servers].some(server => tool.startsWith('mcp__' + server + '__'));
    requireValue(tools.has(tool) || (mcp && config.networkAllowed && config.mode === 'workspace-write'),
      'tool_not_allowed');
    const payload = { tool, input, digest: digest({ tool, input }), relativePaths: [] };
    const selectedPath = input.file_path ?? input.notebook_path ?? input.path;
    if (reads.includes(tool) || writes.includes(tool)) {
      const target = path.resolve(root, selectedPath === undefined ? '.' : text(selectedPath, 16384));
      const inProject = contained(root, target);
      const resolvedTarget = inProject || writes.includes(tool) ? target : await realpath(target);
      const scope = writes.includes(tool) ? readRoots[0]
        : readRoots.find(item => contained(item.path, resolvedTarget));
      requireValue(scope && (writes.includes(tool) ? contained(root, target) : true), 'path_outside_project');
      const relative = path.relative(scope.path, resolvedTarget);
      requireValue(!writes.includes(tool) || relative.length > 0, 'file_path_required');
      const components = relative ? relative.split(path.sep) : [];
      requireValue(!components.some(part => blocked.has(part.toLowerCase()) || /^\.env(?:\.|$)/iu.test(part)),
        'sensitive_path_denied');
      let cursor = scope.path;
      for (const component of components) {
        cursor = path.join(cursor, component);
        try {
          const info = await lstat(cursor);
          requireValue(!info.isSymbolicLink() && info.nlink <= 1 || info.isDirectory() && !info.isSymbolicLink(),
            'linked_path_denied');
        } catch (error) {
          if (tool === 'Write' && error.code === 'ENOENT') break;
          throw error;
        }
      }
      if (relative) payload.relativePaths.push(scope.display + relative.split(path.sep).join('/'));
    }
    if (tool === 'Bash') payload.command = text(input.command, 8192);
    if (tool === 'WebSearch') payload.networkTarget = 'web search';
    if (tool === 'WebFetch') {
      const url = new URL(text(input.url, 4096));
      requireValue(['https:', 'http:'].includes(url.protocol) && !url.username && !url.password, 'invalid_web_url');
      payload.networkTarget = url.href;
    }
    if (mcp) payload.networkTarget = 'MCP server: ' + [...servers].find(server => tool.startsWith('mcp__' + server + '__'));
    payload.needsApproval = !reads.includes(tool) && !plans.includes(tool) && tool !== userInput;
    return payload;
  }
  async function decide(tool, input, options) {
    const checked = await check(tool, input);
    if (tool === userInput) return userAnswer(input, options, requestUserInput);
    if (!checked.needsApproval) return { behavior: 'allow', updatedInput: input };
    const id = identifier(options.toolUseID, 200);
    const key = id + ':' + checked.digest;
    requireValue(decisions.size < 256 || decisions.has(key), 'too_many_pending_tools');
    if (sessionRules.has(checked.digest)) return { behavior: 'allow', updatedInput: input };
    if (decisions.has(key)) return decisions.get(key);
    const decision = requestPermission({ ...checked, input: undefined, toolUseID: id,
      agentID: options.agentID ?? null }, options.signal).then(async answer => {
      requireValue(!options.signal?.aborted, 'interaction_cancelled');
      await check(tool, input);
      requireValue(answer?.digest === checked.digest, 'permission_payload_mismatch');
      if (answer.option === 'allow_for_session') {
        requireValue(sessionRules.size < 256, 'session_rule_limit');
        sessionRules.add(checked.digest);
      }
      if (answer.option === 'allow_once' || answer.option === 'allow_for_session') {
        return { behavior: 'allow', updatedInput: input };
      }
      return { behavior: 'deny', message: 'The local user declined the operation.' };
    }).catch(() => ({ behavior: 'deny', message: 'The operation was not authorized.' }));
    decisions.set(key, decision);
    return decision;
  }
  async function userAnswer(input, options, request) {
    requireValue(typeof request === 'function', 'user_input_unavailable');
    const questions = normalizeQuestions(input.questions);
    const id = identifier(options.toolUseID, 128);
    const response = await request({ toolUseID: id, questions }, options.signal);
    requireValue(!options.signal?.aborted, 'interaction_cancelled');
    if (response?.cancelled === true) return { behavior: 'deny', message: 'The user cancelled the question.' };
    object(response?.answers);
    const answers = {};
    for (const [index, question] of questions.entries()) {
      const values = response.answers[String(index)];
      requireValue(Array.isArray(values) && values.length > 0 && values.length <= question.options.length + 1
        && (question.multiSelect || values.length === 1) && new Set(values).size === values.length,
        'invalid_user_answer');
      requireValue(values.every(value => typeof value === 'string'
        && value.trim().length > 0 && Buffer.byteLength(value) <= 4096 && !value.includes('\0')),
        'invalid_user_answer');
      answers[question.question] = question.multiSelect ? values.join(', ') : values[0];
    }
    requireValue(Object.keys(response.answers).length === questions.length, 'invalid_user_answer');
    return { behavior: 'allow', updatedInput: { ...input, answers } };
  }
  async function preTool(input, id, options) {
    try {
      requireValue(input.hook_event_name === 'PreToolUse' && samePath(root, absolute(input.cwd)), 'tool_workspace_mismatch');
      if (input.tool_name === userInput) return {};
      const result = await decide(input.tool_name, object(input.tool_input), {
        toolUseID: id ?? input.tool_use_id, signal: options.signal, agentID: input.agent_id,
      });
      if (result.behavior === 'allow') return {};
      return { hookSpecificOutput: { hookEventName: 'PreToolUse',
        permissionDecision: 'deny', permissionDecisionReason: result.message } };
    } catch { return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
      permissionDecisionReason: 'The operation is outside the approved task policy.' } }; }
  }
  function finishTool(id) {
    for (const key of decisions.keys()) if (key.startsWith(id + ':')) decisions.delete(key);
  }
  return { tools: [...tools], check, decide, preTool, finishTool,
    close: () => { decisions.clear(); sessionRules.clear(); } };
}

function normalizeQuestions(values) {
  requireValue(Array.isArray(values) && values.length >= 1 && values.length <= 4, 'invalid_user_questions');
  const questions = values.map(value => {
    object(value);
    const question = text(value.question, 4096);
    const header = text(value.header, 512);
    requireValue(Array.isArray(value.options) && value.options.length >= 2 && value.options.length <= 4,
      'invalid_user_options');
    const options = value.options.map(option => {
      object(option);
      return { label: text(option.label, 512), description: typeof option.description === 'string'
        ? text(option.description, 1024, true) : '' };
    });
    requireValue(new Set(options.map(option => option.label)).size === options.length, 'duplicate_user_option');
    return { question, header, options, multiSelect: value.multiSelect === true };
  });
  requireValue(new Set(questions.map(question => question.question)).size === questions.length, 'duplicate_user_question');
  return questions;
}
