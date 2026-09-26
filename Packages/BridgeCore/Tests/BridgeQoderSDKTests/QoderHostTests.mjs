import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, writeFile, readFile, readdir, realpath, symlink, rm } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { PassThrough } from 'node:stream';
import { MessageInput, TurnQueue } from '../../Sources/BridgeQoderSDK/Resources/QoderHost/input.mjs';
import { catalog, validateSelection, modelPolicy } from '../../Sources/BridgeQoderSDK/Resources/QoderHost/models.mjs';
import { createPolicy, toolSelection } from '../../Sources/BridgeQoderSDK/Resources/QoderHost/policy.mjs';
import { QoderSession, validateConfiguration } from '../../Sources/BridgeQoderSDK/Resources/QoderHost/session.mjs';
import { MessageProjection } from '../../Sources/BridgeQoderSDK/Resources/QoderHost/events.mjs';
import { RPCPeer } from '../../Sources/BridgeQoderSDK/Resources/QoderHost/rpc.mjs';
import { packageName, sdkBrand } from '../../Sources/BridgeQoderSDK/Resources/QoderHost/sdk.mjs';
import { contained, digest, HostError } from '../../Sources/BridgeQoderSDK/Resources/QoderHost/validation.mjs';

async function fixture(t, overrides = {}) {
  const base = path.join(process.cwd(), '.build', 'qoder-tests'); await mkdir(base, { recursive: true });
  const cwd = await realpath(await mkdtemp(path.join(base, 'run-')));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  await writeFile(path.join(cwd, 'sample.txt'), 'original');
  return { revision: 1, distribution: 'cn', cwd, cliPath: path.join(cwd, 'qodercn'), nodePath: process.execPath,
    sdkRoot: path.join(cwd, 'sdk'),
    sessionID: randomUUID(), resume: false, persist: true, mode: 'workspace-write', networkAllowed: true,
    model: 'test-model', skills: [], selectedSkills: [], mcpServers: {}, ...overrides };
}
const model = { value: 'test-model', displayName: 'Test model', isEnabled: true,
  thinking_config: { disabled: {}, enabled: { efforts: { low: {}, high: { is_default: true } } } } };
const wait = () => new Promise(resolve => setImmediate(resolve));
async function until(predicate) {
  const end = Date.now() + 2000;
  while (!predicate()) { if (Date.now() > end) throw new Error('Condition timeout'); await wait(); }
}
class QueryFixture {
  constructor(config) {
    this.config = config; this.messages = new MessageInput(); this.closed = 0; this.stopIDs = [];
    this.messages.send({ type: 'system', subtype: 'init', cwd: config.cwd,
      tools: ['Agent', 'AskUserQuestion', 'Bash', 'Edit', 'Glob', 'Grep', 'NotebookEdit', 'Read', 'Skill',
        'TaskCreate', 'TaskGet', 'TaskUpdate', 'TaskList', 'UpdateGoal', 'WebFetch', 'WebSearch', 'Write'],
      skills: config.selectedSkills.map(skill => skill.name),
      mcp_servers: [], capabilities: ['selected_skills_v1', 'background_tasks_v1', 'plan_mode_v1'] });
  }
  initializationResult() { return Promise.resolve({ skills: [] }); }
  getAvailableModels() { return Promise.resolve([model]); }
  getContextUsage() { return Promise.resolve({ contextWindow: { usedPercentage: 67 } }); }
  accountInfo() { return Promise.resolve({ userId: 'fixture-account-id' }); }
  interrupt() {
    this.messages.send({ type: 'result', subtype: 'error_during_execution', is_error: true,
      session_id: this.config.sessionID, errors: ['cancelled'] });
    return Promise.resolve({ still_queued: [] });
  }
  stopTask(id) { this.stopIDs.push(id); return Promise.resolve(); }
  close() { this.closed += 1; this.messages.close(); }
  [Symbol.asyncIterator]() { return this.messages; }
}
async function sessionFixture(t, overrides = {}) {
  const config = await fixture(t, overrides); const events = []; const query = new QueryFixture(config);
  let captured; let starts = 0; let activeQuery = query;
  const sdk = { qodercliAuth: () => ({ type: 'fixture' }), ProcessTransport: { default: {} },
    getSessionInfo: async id => ({ sessionId: id, cwd: config.cwd }),
    startup: async ({ options }) => {
      starts += 1;
      const selectedQuery = starts === 1 ? new QueryFixture(config) : query;
      if (starts > 1) { captured = options; activeQuery = selectedQuery; }
      return { query: input => { selectedQuery.input = input; return selectedQuery; }, close() {} };
    } };
  const session = new QoderSession(event => events.push(event), async (_method, params) => ({ option: 'deny', digest: params.digest }),
    async () => ({ sdk, cliVersion: '1.0.0', sdkVersion: '1.0.0' }));
  const opened = await session.open(config); t.after(() => session.close());
  return { config, events, query: activeQuery, session, options: captured, sdk, opened };
}
function result(config, text = 'finished') {
  return { type: 'result', session_id: config.sessionID, subtype: 'success', is_error: false,
    result: text, usage: { input_tokens: 3, output_tokens: 2 } };
}

test('distribution names select different official packages', () => {
  assert.equal(packageName('cn'), '@qodercn-ai/qodercn-agent-sdk');
  assert.equal(packageName('international'), '@qoder-ai/qoder-agent-sdk');
  assert.throws(() => packageName('other'));
  assert.equal(sdkBrand('cn'), 'cn'); assert.equal(sdkBrand('international'), 'global');
  assert.throws(() => sdkBrand('other'));
});
test('model catalog includes only enabled models and authentic effort values', () => {
  const values = catalog([model, { value: 'off', isEnabled: false }]);
  assert.deepEqual(values[0].efforts, ['none', 'low', 'high']); assert.equal(values[0].defaultEffort, 'high');
  assert.equal(values.length, 1);
});
test('model catalog advertises image input only when the official model field confirms vision', () => {
  assert.deepEqual(catalog([{ value: 'vision', isVl: true }])[0].inputModalities, ['text', 'image']);
  assert.deepEqual(catalog([{ value: 'text', isVl: false }])[0].inputModalities, ['text']);
  assert.equal(catalog([{ value: 'unknown' }])[0].inputModalities, null);
});
test('model catalog exposes only an explicit default context window', () => {
  assert.equal(catalog([{ value: 'configured', defaultContextWindow: 131072 }])[0].contextWindow, 131072);
  assert.equal(catalog([{ value: 'unknown', maxInputTokens: 999999 }])[0].contextWindow, null);
  assert.equal(catalog([{ value: 'tiered', context_config: { small: { token_count: 64000, is_default: true },
    large: { token_count: 128000 } } }])[0].contextWindow, 64000);
});
test('missing model effort metadata remains unknown', () => {
  const value = catalog([{ value: 'plain', isEnabled: true }])[0];
  assert.equal(value.effortsKnown, false); assert.deepEqual(value.efforts, []);
});
test('duplicate model IDs are rejected', () => { assert.throws(() => catalog([model, model])); });
test('model and reasoning selection never silently falls back', () => {
  assert.throws(() => validateSelection(catalog([model]), 'other'));
  assert.throws(() => validateSelection(catalog([model]), 'test-model', 'extreme'));
  assert.throws(() => modelPolicy(null, 'high'));
  assert.deepEqual(modelPolicy('test-model', 'high').resolveModel({ availableModels: [model] }),
    { model: 'test-model', parameters: { reasoningEffort: 'high' } });
});
test('input stream remains open between messages', async () => {
  const input = new MessageInput(); const first = input.next(); input.send('one');
  assert.equal((await first).value, 'one'); const second = input.next(); input.send('two');
  assert.equal((await second).value, 'two'); input.close(); assert.equal((await input.next()).done, true);
});
test('turn queue has one current input and no duplicate IDs', () => {
  const queue = new TurnQueue(); const first = { id: randomUUID(), text: 'one' };
  queue.push(first); assert.throws(() => queue.push(first)); assert.equal(queue.take().id, first.id);
  assert.throws(() => queue.take()); queue.finish(); assert.equal(queue.empty, true);
});
test('queue cancellation does not cancel current input', () => {
  const queue = new TurnQueue(); queue.push({ id: randomUUID(), text: 'a' }); queue.take();
  const id = randomUUID(); queue.push({ id, text: 'b' }); assert.deepEqual(queue.cancelPending(), [id]);
  assert.notEqual(queue.current, null); queue.finish(); assert.equal(queue.empty, true);
});
test('queue limits are enforced before accepting input', () => {
  const queue = new TurnQueue();
  for (let index = 0; index < 32; index += 1) queue.push({ id: randomUUID(), text: 'a' });
  assert.throws(() => queue.push({ id: randomUUID(), text: 'a' }));
});
test('configuration requires a supported region and exact UUID', async t => {
  const config = await fixture(t);
  assert.throws(() => validateConfiguration({ ...config, distribution: 'auto' }));
  assert.throws(() => validateConfiguration({ ...config, sessionID: 'latest' }));
});
test('configuration does not allow network MCP under network denial', async t => {
  const config = await fixture(t);
  assert.throws(() => validateConfiguration({ ...config, networkAllowed: false,
    mcpServers: { service: { type: 'http', url: 'https://example.com/mcp' } } }));
});
test('configuration rejects unrecognized MCP transports and relative commands', async t => {
  const config = await fixture(t);
  assert.throws(() => validateConfiguration({ ...config, mcpServers: { service: { type: 'stdio', command: 'node' } } }));
  assert.throws(() => validateConfiguration({ ...config, mcpServers: { service: { type: 'custom' } } }));
});
test('read only tool selection keeps questions and plans while excluding writes and network tools', () => {
  const values = toolSelection({ mode: 'read-only', networkAllowed: true });
  assert.deepEqual(values, ['Read', 'Glob', 'Grep', 'AskUserQuestion',
    'TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskList', 'UpdateGoal']);
});
test('selected Bridge Skill files are staged as an official additional directory and attached to user input', async t => {
  const skill = { name: 'trace-helper', source: 'project', contentVersion: 'a'.repeat(64), files: [
    { relativePath: 'SKILL.md', content: '---\nname: old-name\ndescription: Trace\n---\n\nRead the trace.' },
    { relativePath: 'references/format.md', content: 'Use one event per line.' },
  ] };
  const { session, query, config, options } = await sessionFixture(t, {
    skills: [skill.name], selectedSkills: [skill],
  });
  const directory = options.additionalDirectories[0];
  const skillDirectory = (await readdir(path.join(directory, '.agents', 'skills')))[0];
  const root = path.join(directory, '.agents', 'skills', skillDirectory);
  const manifest = await readFile(path.join(root, 'SKILL.md'), 'utf8');
  const reference = await readFile(path.join(root, 'references', 'format.md'), 'utf8');
  assert.match(manifest, /name: "trace-helper"/u);
  assert.equal(reference, 'Use one event per line.');
  const read = await session.policy.check('Read', {
    file_path: path.join(root, 'references', 'format.md'),
  });
  assert.equal(read.relativePaths[0].startsWith('.selected-skills/.agents/skills/'), true);
  await assert.rejects(session.policy.check('Write', {
    file_path: path.join(root, 'references', 'format.md'), content: 'outside project',
  }));
  await session.dispatchInput({ id: randomUUID(), text: 'Use the selected skill.' });
  assert.deepEqual((await query.input.next()).value.selected_skills, [{ name: 'trace-helper' }]);
  assert.equal(config.selectedSkills[0].contentVersion, skill.contentVersion);
});
test('read only policy rejects a write even if a local decision would allow', async t => {
  const config = await fixture(t, { mode: 'read-only' }); let calls = 0;
  const policy = await createPolicy(config, async () => { calls += 1; return { option: 'allow_once' }; });
  await assert.rejects(policy.decide('Write', { file_path: 'sample.txt', content: 'new' }, { toolUseID: 'a' }));
  assert.equal(calls, 0);
});
test('local allow applies to the exact tool payload', async t => {
  const config = await fixture(t); let calls = 0;
  const policy = await createPolicy(config, async params => { calls += 1; return { option: 'allow_for_session', digest: params.digest }; });
  const input = { file_path: 'sample.txt', content: 'first' };
  assert.equal((await policy.decide('Write', input, { toolUseID: 'a' })).behavior, 'allow'); policy.finishTool('a');
  assert.equal((await policy.decide('Write', input, { toolUseID: 'b' })).behavior, 'allow');
  await policy.decide('Write', { ...input, content: 'changed' }, { toolUseID: 'c' }); assert.equal(calls, 2);
});
test('mismatched approval digest is rejected', async t => {
  const config = await fixture(t); const policy = await createPolicy(config, async () => ({ option: 'allow_once', digest: 'wrong' }));
  assert.equal((await policy.decide('Bash', { command: 'echo sample' }, { toolUseID: 'a' })).behavior, 'deny');
});
test('structured Qoder questions return answers through the official updatedInput field', async t => {
  const config = await fixture(t);
  let request;
  const policy = await createPolicy(config, async () => ({}), async value => {
    request = value;
    return { answers: { '0': ['custom color'], '1': ['one', 'two'] } };
  });
  const input = { questions: [
    { question: 'Color?', header: 'Color', options: [{ label: 'blue' }, { label: 'red' }] },
    { question: 'Which?', header: 'Choice', multiSelect: true,
      options: [{ label: 'one' }, { label: 'two' }] },
  ] };
  const result = await policy.decide('AskUserQuestion', input, { toolUseID: 'tool-1' });
  assert.deepEqual(request.questions.map(value => value.question), ['Color?', 'Which?']);
  assert.deepEqual(result.updatedInput.answers, { 'Color?': 'custom color', 'Which?': 'one, two' });
});
test('tool requests that escape project or target secrets are rejected', async t => {
  const config = await fixture(t); const policy = await createPolicy(config, async () => ({}));
  await assert.rejects(policy.check('Read', { file_path: '../outside' }));
  await assert.rejects(policy.check('Read', { file_path: '.env' }));
});
test('linked file targets are rejected', async t => {
  const config = await fixture(t); await symlink(path.join(config.cwd, 'sample.txt'), path.join(config.cwd, 'link.txt'));
  const policy = await createPolicy(config, async () => ({}));
  await assert.rejects(policy.check('Read', { file_path: 'link.txt' }));
});
test('policy hook fails closed on invalid input', async t => {
  const config = await fixture(t); const policy = await createPolicy(config, async () => ({}));
  assert.equal((await policy.preTool({ hook_event_name: 'PreToolUse', cwd: config.cwd, tool_name: 'Unknown', tool_input: {} }, 'a', {}))
    .hookSpecificOutput.permissionDecision, 'deny');
});
test('Windows paths use drive case and separator equivalence', () => {
  assert.equal(contained('D:\\Code', 'd:/Code/a.txt', path.win32), true);
  assert.equal(contained('D:\\Code', 'D:\\CodeOther\\a.txt', path.win32), false);
  assert.equal(contained('D:\\Code', 'E:\\Code\\a.txt', path.win32), false);
});
test('canonical payload identity ignores object order but not values', () => {
  assert.equal(digest({ a: 1, b: 2 }), digest({ b: 2, a: 1 })); assert.notEqual(digest({ a: 1 }), digest({ a: 2 }));
});
test('stream fragments and final text share a stable message key', async () => {
  const events = []; const projection = new MessageProjection(value => events.push(value));
  await projection.message({ type: 'stream_event', event: { type: 'message_start', message: { id: 'm1' } } });
  await projection.message({ type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'hello' } } });
  await projection.message({ type: 'assistant', uuid: 'transport-uuid', message: { content: [{ type: 'text', text: 'hello world' }] } });
  assert.equal(events[0].key, events[1].key); assert.equal(events[1].mode, 'full');
});
test('tool lifecycle records actual completion and plan state', async () => {
  const events = []; const projection = new MessageProjection(value => events.push(value));
  await projection.message({ type: 'assistant', uuid: 'm1', message: { content: [{ type: 'tool_use', id: 't1', name: 'TodoWrite',
    input: { todos: [{ content: 'test', status: 'completed' }] } }] } });
  assert.equal(projection.tools.size, 1);
  await projection.message({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: 'done' }] } });
  assert.equal(projection.tools.size, 0); assert.equal(events.at(-1).kind, 'plan');
});
test('missing background tasks are unknown until a terminal event', async () => {
  const projection = new MessageProjection(() => {});
  await projection.message({ type: 'system', subtype: 'task_started', task_id: 'child1' });
  await projection.message({ type: 'system', subtype: 'background_tasks_changed', tasks: [] });
  assert.equal(projection.unsettledChildren.length, 1);
  await projection.message({ type: 'system', subtype: 'task_notification', task_id: 'child1', status: 'completed' });
  assert.equal(projection.unsettledChildren.length, 0);
});
test('open initializes SDK from native init metadata without sending model input', async t => {
  const { session, query, options, opened } = await sessionFixture(t);
  assert.equal(session.phase, 'ready'); assert.equal(query.input.message, null);
  assert.deepEqual(options.settingSources, ['user']); assert.equal(options.permissionMode, 'default');
  assert.equal(options.persistSession, true);
  assert.equal(options.executable, process.execPath); assert.equal(options.transport, session.sdk.ProcessTransport.default);
  assert(opened.nativeTools.includes('WebSearch'));
  assert(opened.nativeCapabilities.includes('selected_skills_v1'));
  assert(opened.queryMethods.includes('stopTask'));
  assert.match(opened.accountScopeDigest, /^[0-9a-f]{64}$/u);
  assert.equal(opened.accountScopeDigest.includes('fixture-account-id'), false);
});
test('resume rejects a changed account scope before reading native session metadata', async t => {
  const config = await fixture(t, { resume: true, expectedAccountScope: '0'.repeat(64) });
  const query = new QueryFixture(config); let sessionInfoReads = 0;
  const sdk = { qodercliAuth: () => ({}), ProcessTransport: { default: {} },
    accountInfo: async () => ({ userId: 'unused' }),
    getSessionInfo: async () => { sessionInfoReads += 1; return { sessionId: config.sessionID, cwd: config.cwd }; },
    startup: async () => ({ query: () => query, close() {} }) };
  const session = new QoderSession(() => {}, async () => ({}), async () => ({ sdk }));
  await assert.rejects(session.open(config), error => error.code === 'session_account_mismatch');
  assert.equal(sessionInfoReads, 0);
});
test('queued followup is delivered only after current result', async t => {
  const { session, query, config, events } = await sessionFixture(t);
  const a = randomUUID(), b = randomUUID(); await session.dispatchInput({ id: a, text: 'one' });
  const first = await query.input.next(); assert.equal(first.value.uuid, a);
  await session.dispatchInput({ id: b, text: 'two' }); assert.equal(query.input.message, null);
  query.messages.send(result(config)); await until(() => session.queue.current?.id === b);
  assert.equal((await query.input.next()).value.uuid, b);
  query.messages.send(result(config, 'second')); await until(() => session.phase === 'closed');
  assert.equal(events.filter(value => value.kind === 'completed').length, 1);
  assert.equal(query.closed, 1);
});
test('Qoder SDK input maps selected image bytes to the official content-block shape', async t => {
  const { session, query, config } = await sessionFixture(t);
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const data = bytes.toString('base64');
  await session.dispatchInput({ id: randomUUID(), text: 'Describe this image',
    images: [{ mimeType: 'image/png', data }] });
  const message = await query.input.next();
  assert.equal(message.value.session_id, config.sessionID);
  assert.deepEqual(message.value.message.content, [
    { type: 'text', text: 'Describe this image' },
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data } },
  ]);
});
test('Qoder image queue rejects unsupported MIME and non-canonical base64', () => {
  const queue = new TurnQueue();
  const id = randomUUID();
  assert.throws(() => queue.push({ id, text: 'image', images: [{ mimeType: 'image/gif', data: 'AQ==' }] }));
  assert.throws(() => queue.push({ id, text: 'image', images: [{ mimeType: 'image/png', data: 'AQ' }] }));
  assert.equal(queue.empty, true);
});
test('late input is rejected after terminal transition', async t => {
  const { session, query, config } = await sessionFixture(t);
  await session.dispatchInput({ id: randomUUID(), text: 'one' }); await query.input.next();
  query.messages.send(result(config)); await until(() => session.phase === 'closed');
  await assert.rejects(session.dispatchInput({ id: randomUUID(), text: 'late' }));
});
test('interruption clears pending input and closes SDK', async t => {
  const { session, query, events } = await sessionFixture(t);
  await session.dispatchInput({ id: randomUUID(), text: 'one' }); await query.input.next();
  await session.dispatchInput({ id: randomUUID(), text: 'two' });
  const outcome = await session.interrupt(); assert.equal(outcome.cancelled.length, 1);
  assert.equal(query.closed, 1); assert.equal(events.at(-1).kind, 'interrupted');
});
test('interrupt then continue preserves session identity and sends once', async t => {
  const { session, query, config } = await sessionFixture(t);
  await session.dispatchInput({ id: randomUUID(), text: 'one' }); await query.input.next();
  const id = randomUUID(); const result = await session.interrupt({ id, text: 'next' });
  assert.equal(result.inputID, id); const message = await query.input.next();
  assert.equal(message.value.uuid, id); assert.equal(message.value.session_id, config.sessionID);
  assert.equal(query.closed, 0);
});
test('success result cannot settle while child remains active', async t => {
  const { session, query, config, events } = await sessionFixture(t);
  await session.dispatchInput({ id: randomUUID(), text: 'one' }); await query.input.next();
  query.messages.send({ type: 'system', subtype: 'task_started', task_id: 'child' });
  await until(() => session.projection.children.size === 1);
  query.messages.send(result(config)); await wait(); await wait();
  assert.equal(events.some(value => value.kind === 'completed'), false); assert.equal(query.closed, 0);
  query.messages.send({ type: 'system', subtype: 'task_updated', task_id: 'child', patch: { status: 'completed' } });
  await until(() => session.projection.children.get('child')?.status === 'completed');
  await session.close();
});
test('native wrong session is rejected without completing the task', async t => {
  const { session, query, events } = await sessionFixture(t);
  await session.dispatchInput({ id: randomUUID(), text: 'one' }); await query.input.next();
  query.messages.send({ type: 'result', session_id: randomUUID(), subtype: 'success', result: 'wrong' });
  await until(() => session.phase === 'closed'); assert.equal(events.at(-1).kind, 'failed');
});
test('result statistics preserve provider counters and use only explicit USD cost', async t => {
  const { session, query, config, events } = await sessionFixture(t);
  await session.dispatchInput({ id: randomUUID(), text: 'one' }); await query.input.next();
  query.messages.send({ ...result(config), usage: { input_tokens: 10, output_tokens: 7,
    cache_read_input_tokens: 3, cache_creation_input_tokens: 2, context_usage_ratio: 0.8 },
    modelUsage: { model: { contextWindow: 128000 } }, total_cost_usd: 0.25 });
  await until(() => session.phase === 'closed');
  assert.deepEqual(events.find(value => value.kind === 'usage_statistics').statistics, {
    inputTokens: 10, outputTokens: 7, cacheReadTokens: 3, cacheWriteTokens: 2,
    totalTokens: 17, contextWindow: 128000, costAmount: 0.25, currency: 'USD', contextUsedPercentage: 67,
  });
});
test('RPC handles an approval response while a command waits', async () => {
  const input = new PassThrough(), output = new PassThrough(); const records = [];
  output.on('data', bytes => records.push(JSON.parse(bytes.toString())));
  let peer;
  peer = new RPCPeer(input, output, async () => peer.request('qoder/permission', { digest: 'a' }));
  input.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'qoder/input', params: {} }) + '\n');
  await until(() => records.length === 1);
  input.write(JSON.stringify({ jsonrpc: '2.0', id: records[0].id, result: { option: 'deny' } }) + '\n');
  await until(() => records.length === 2); assert.equal(records[1].id, 1);
  await peer.close(); input.destroy(); output.destroy();
});
test('RPC parses chunked Unicode and CRLF', async () => {
  const input = new PassThrough(), output = new PassThrough(); const records = [];
  output.on('data', bytes => records.push(JSON.parse(bytes.toString())));
  const peer = new RPCPeer(input, output, async (_method, params) => params);
  const bytes = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'qoder/input', params: { text: '中文\u2028🙂' } }) + '\r\n');
  for (const byte of bytes) input.write(Buffer.from([byte]));
  await until(() => records.length === 1); assert.equal(records[0].result.text, '中文\u2028🙂');
  await peer.close(); input.destroy(); output.destroy();
});
test('RPC rejects duplicate active request IDs', async () => {
  const input = new PassThrough(), output = new PassThrough();
  const peer = new RPCPeer(input, output, async () => new Promise(() => {}));
  const line = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'qoder/input', params: {} }) + '\n';
  input.write(line + line); await until(() => peer.closed); input.destroy(); output.destroy();
});


test('catalog accepts the official enabled default when the field is omitted', () => {
  assert.equal(catalog([{ value: 'default-enabled' }])[0].id, 'default-enabled');
});
test('interrupt continuation reports cancelled queued identities', async t => {
  const { session, query, events } = await sessionFixture(t);
  await session.dispatchInput({ id: randomUUID(), text: 'first' }); await query.input.next();
  const queuedID = randomUUID(); await session.dispatchInput({ id: queuedID, text: 'queued' });
  await session.interrupt({ id: randomUUID(), text: 'replacement' });
  assert.deepEqual(events.find(value => value.kind === 'inputs_cancelled').inputIDs, [queuedID]);
  assert.equal((await query.input.next()).value.message.content[0].text, 'replacement');
});
test('interrupt continuation waits for native child cancellation event', async t => {
  const { session, query } = await sessionFixture(t);
  await session.dispatchInput({ id: randomUUID(), text: 'first' }); await query.input.next();
  query.messages.send({ type: 'system', subtype: 'task_started', task_id: 'child' });
  await until(() => session.projection.children.has('child'));
  query.stopTask = async id => {
    query.stopIDs.push(id);
    setTimeout(() => query.messages.send({ type: 'system', subtype: 'task_updated', task_id: id,
      patch: { status: 'killed' } }), 30);
  };
  await session.interrupt({ id: randomUUID(), text: 'replacement' });
  assert.equal(session.projection.children.get('child').status, 'stopped');
  assert.equal((await query.input.next()).value.message.content[0].text, 'replacement');
});

test('runtime hashes cover all shipped host modules and match their contents', async () => {
  const base = new URL('../../Sources/BridgeQoderSDK/', import.meta.url);
  const manifest = await readFile(new URL('QoderRuntimeResources.swift', base), 'utf8');
  const entries = new Map([...manifest.matchAll(/"([^"\n]+\.mjs)": "([0-9a-f]{64})"/gu)]
    .map(match => [match[1], match[2]]));
  const files = (await readdir(new URL('Resources/QoderHost/', base))).filter(name => name.endsWith('.mjs'));
  assert.equal(entries.size, files.length);
  for (const name of files) {
    const data = await readFile(new URL('Resources/QoderHost/' + name, base));
    assert.equal(createHash('sha256').update(data).digest('hex'), entries.get(name));
  }
});

test('SDK process owner confirms native child termination', async () => {
  const { SDKProcessOwner } = await import('../../Sources/BridgeQoderSDK/Resources/QoderHost/process.mjs');
  const owner = new SDKProcessOwner();
  const child = owner.spawn({ command: process.execPath, args: ['-e', 'setInterval(() => {}, 1000)'],
    cwd: process.cwd(), env: process.env });
  await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
  child.kill('SIGTERM');
  await owner.close();
  assert.ok(child.exitCode !== null || child.signalCode !== null);
  assert.equal(owner.children.size, 0);
});
