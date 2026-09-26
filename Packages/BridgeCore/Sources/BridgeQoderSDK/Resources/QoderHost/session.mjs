import { MessageInput, TurnQueue } from './input.mjs';
import { validateConfiguration } from './configuration.mjs';
export { validateConfiguration } from './configuration.mjs';
import { createPolicy } from './policy.mjs';
import { MessageProjection, stopChildren } from './events.mjs';
import { catalog, modelPolicy, validateSelection } from './models.mjs';
import { loadSDK, authentication, validateSDKQuery } from './sdk.mjs';
import { SDKProcessOwner } from './process.mjs';
import { queryAccountScope } from './account-scope.mjs';
import { stageSelectedSkills } from './skill-resources.mjs';
import { usageStatistics, contextView, usageInfoView } from './usage.mjs';
import { requireValue, absolute, identifier, deadline, HostError, samePath } from './validation.mjs';

export class QoderSession {
  constructor(emit, ask, loader = loadSDK) {
    this.emit = emit; this.ask = ask; this.loader = loader; this.phase = 'new';
    this.input = new MessageInput(); this.queue = new TurnQueue();
    this.projection = new MessageProjection(value => this.publish(value));
    this.interactions = new AbortController(); this.closing = null; this.resultWaiter = null;
    this.sequence = 0; this.query = null; this.warm = null; this.nativeCapabilities = new Set();
    this.nativeTools = new Set(); this.nativeSkills = []; this.mcpServers = [];
    this.nativeInitialization = new Promise(resolve => { this.resolveNativeInitialization = resolve; });
    this.processes = new SDKProcessOwner();
  }
  publish(value) {
    if (this.phase === 'closed') return;
    requireValue(this.sequence < Number.MAX_SAFE_INTEGER, 'sequence_overflow');
    this.emit({ ...value, sequence: this.sequence++, sessionID: this.config?.sessionID,
      distribution: this.config?.distribution });
  }
  async open(raw) {
    requireValue(this.phase === 'new', 'session_already_open'); this.phase = 'opening';
    this.config = validateConfiguration(raw);
    try {
      const loaded = await this.loader(this.config);
      requireValue(this.phase === 'opening', 'session_closed'); this.sdk = loaded.sdk;
      this.skillStage = await stageSelectedSkills(this.config.selectedSkills);
      this.accountScopeDigest = await queryAccountScope(this.sdk, this.config);
      requireValue(!this.config.expectedAccountScope || this.config.expectedAccountScope === this.accountScopeDigest,
        'session_account_mismatch');
      if (this.config.resume) {
        const previous = await deadline(this.sdk.getSessionInfo(this.config.sessionID, { dir: this.config.cwd }));
        requireValue(previous?.sessionId === this.config.sessionID && previous.cwd
          && samePath(absolute(previous.cwd), this.config.cwd), 'session_binding_mismatch');
      }
      this.policy = await createPolicy(this.config, (value, signal) => this.ask('qoder/permission', value,
        AbortSignal.any([signal ?? new AbortController().signal, this.interactions.signal])),
      (value, signal) => this.ask('qoder/question', value,
        AbortSignal.any([signal ?? new AbortController().signal, this.interactions.signal])),
      { additionalReadRoots: this.skillStage ? [this.skillStage.root] : [] });
      const options = this.options();
      const warm = await deadline(this.sdk.startup({ options, initializeTimeoutMs: 30000 }), 35000);
      if (this.phase !== 'opening') { await warm.close(); throw new HostError('session_closed'); }
      this.warm = warm;
      this.query = this.warm.query(this.input); validateSDKQuery(this.query);
      this.pump = this.consume();
      const initialization = await deadline(this.query.initializationResult());
      await deadline(this.nativeInitialization, 30000);
      this.nativeCapabilities = new Set(initialization.capabilities ?? this.nativeCapabilities);
      requireValue(this.config.selectedSkills.every(skill => this.nativeSkills.includes(skill.name)),
        'selected_skill_unavailable');
      requireValue(this.config.selectedSkills.length === 0 || this.nativeCapabilities.has('selected_skills_v1'),
        'selected_skills_unavailable');
      const models = catalog(await deadline(this.query.getAvailableModels()));
      validateSelection(models, this.config.model, this.config.effort);
      requireValue(this.phase === 'opening', 'session_open_failed'); this.phase = 'ready';
      return { revision: 1, distribution: this.config.distribution, sessionID: this.config.sessionID,
        sdkVersion: loaded.sdkVersion, cliVersion: loaded.cliVersion, models,
        accountScopeDigest: this.accountScopeDigest,
        skills: this.nativeSkills.slice(0, 256),
        nativeCapabilities: [...this.nativeCapabilities],
        nativeTools: [...this.nativeTools].slice(0, 256),
        mcpServers: this.mcpServers.slice(0, 32),
        sdkMethods: ['getSessionInfo', 'getSessionMessages']
          .filter(name => typeof this.sdk[name] === 'function'),
        queryMethods: ['interrupt', 'stopTask', 'getContextUsage', 'getUsageInfo', 'setPlanMode', 'getPlanMode', 'setMcpServers']
          .filter(name => typeof this.query[name] === 'function') };
    } catch (error) {
      await this.close();
      if (this.authenticationExpired) throw new HostError('authentication_required');
      throw error;
    }
  }
  options() {
    const config = this.config;
    return { auth: authentication(this.sdk, config), cwd: config.cwd,
      pathToQoderCLIExecutable: config.cliPath, ...modelPolicy(config.model, config.effort),
      transport: this.sdk.ProcessTransport.default, executable: process.execPath,
      onAuthExpired: () => { this.authenticationExpired = true; },
      spawnQoderCLIProcess: options => this.processes.spawn(options),
      ...(config.resume ? { resume: config.sessionID } : { sessionId: config.sessionID }),
      persistSession: config.persist, includePartialMessages: true,
      ...(this.skillStage ? { additionalDirectories: this.skillStage.additionalDirectories } : {}),
      extraArgs: { 'replay-user-messages': null }, settingSources: ['user'],
      settings: {}, tools: this.policy.tools, skills: config.skills, mcpServers: config.mcpServers,
      strictMcpConfig: true, permissionMode: 'default', maxTurns: 100,
      ...(config.proxy ? { proxy: config.proxy } : {}),
      hooks: { PreToolUse: [{ hooks: [async (input, id, options) => {
        if (input.tool_input?.run_in_background && !this.nativeCapabilities.has('background_tasks_v1')) {
          return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
            permissionDecisionReason: 'Background task control is unavailable.' } };
        }
        return this.policy.preTool(input, id, options);
      }] }], PostToolUse: [{ hooks: [async (_input, id) => { this.policy.finishTool(id); return {}; }] }],
      PostToolUseFailure: [{ hooks: [async (_input, id) => { this.policy.finishTool(id); return {}; }] }] },
      canUseTool: (tool, input, options) => this.policy.decide(tool, input, options).catch(() => ({
        behavior: 'deny', message: 'The operation is outside the approved task policy.' })),
    };
  }
  async dispatchInput(value) {
    requireValue(this.phase === 'ready' || this.phase === 'running', 'session_not_accepting_input');
    const id = this.queue.push(value);
    if (this.phase === 'ready') this.beginNext();
    return { accepted: true, inputID: id };
  }
  beginNext() {
    const item = this.queue.take(); if (!item) return;
    this.phase = 'running';
    this.input.send({ type: 'user', uuid: item.id, session_id: this.config.sessionID,
      priority: 'later', parent_tool_use_id: null, client_composed: true,
      ...(this.config.selectedSkills.length
        ? { selected_skills: this.config.selectedSkills.map(skill => ({ name: skill.name })) } : {}),
      message: { role: 'user', content: [
        { type: 'text', text: item.text },
        ...item.images.map(image => ({ type: 'image', source: {
          type: 'base64', media_type: image.mimeType, data: image.data,
        } })),
      ] } });
    this.publish({ kind: 'input_dispatched', inputID: item.id, text: item.text });
  }
  async consume() {
    try {
      for await (const message of this.query) {
        if (message.session_id) requireValue(message.session_id === this.config.sessionID, 'native_session_mismatch');
        if (message.type === 'system' && message.subtype === 'init') {
          requireValue(samePath(absolute(message.cwd), this.config.cwd), 'native_workspace_mismatch');
          this.nativeCapabilities = new Set(message.capabilities ?? []);
          this.nativeTools = new Set(Array.isArray(message.tools) ? message.tools : []);
          this.nativeSkills = Array.isArray(message.skills) ? message.skills.filter(skill => typeof skill === 'string') : [];
          this.mcpServers = Array.isArray(message.mcp_servers) ? message.mcp_servers.filter(server =>
            server && typeof server.name === 'string' && typeof server.status === 'string') : [];
          this.resolveNativeInitialization(); this.resolveNativeInitialization = null;
        }
        await this.projection.message(message);
        if (message.type === 'result') await this.result(message);
      }
      if (!['closing', 'closed'].includes(this.phase)) await this.fail(
        this.authenticationExpired ? 'authentication_required' : 'unexpected_stream_end'
      );
    } catch (error) {
      if (!['closing', 'closed'].includes(this.phase)) await this.fail(
        this.authenticationExpired ? 'authentication_required'
          : error instanceof HostError ? error.code : 'sdk_execution_failed'
      );
    }
  }
  async result(value) {
    const context = value.origin?.kind === 'task-notification' ? null : await this.contextUsage();
    const statistics = usageStatistics(value, context);
    if (statistics) this.publish({ kind: 'usage_statistics', statistics });
    if (this.phase === 'stopping') {
      this.queue.finish();
      if (this.resultWaiter) { this.resultWaiter(); this.resultWaiter = null; }
      return;
    }
    if (this.phase !== 'running') return;
    if (value.origin?.kind !== 'task-notification') this.queue.finish();
    if (value.subtype !== 'success' || value.is_error) { await this.fail('qoder_incomplete_result'); return; }
    if (this.projection.unsettledChildren.length > 0) return;
    requireValue(this.projection.tools.size === 0, 'unfinished_tools');
    if (this.queue.pending.length > 0) { this.beginNext(); return; }
    requireValue(this.queue.empty, 'unfinished_input');
    const summary = typeof value.result === 'string' ? value.result : '';
    requireValue(summary.trim().length > 0, 'empty_result');
    this.phase = 'closing';
    await this.closeResources();
    this.publish({ kind: 'completed', summary: summary.slice(0, 16000), stopReason: 'success' });
    this.phase = 'closed';
  }
  async interrupt(continuation) {
    requireValue(this.phase === 'ready' || this.phase === 'running', 'session_not_interruptible');
    if (continuation) { identifier(continuation.id); requireValue(typeof continuation.text === 'string'
      && continuation.text.trim().length > 0 && Buffer.byteLength(continuation.text) <= 32768, 'invalid_input'); }
    const running = this.queue.current !== null;
    this.phase = 'stopping'; const cancelled = this.queue.cancelPending();
    if (cancelled.length) this.publish({ kind: 'inputs_cancelled', inputIDs: cancelled });
    this.interactions.abort();
    let completed;
    if (running && continuation) completed = new Promise(resolve => { this.resultWaiter = resolve; });
    try {
      const response = await deadline(this.query.interrupt(), 60000);
      requireValue(response === undefined || Array.isArray(response.still_queued), 'invalid_interrupt_reply');
      requireValue(!response?.still_queued?.length, 'native_input_queue_not_empty');
      if (completed) await deadline(completed, 60000);
      if (continuation) await stopChildren(this.query, this.projection, this.nativeCapabilities);
      if (continuation) {
        requireValue(this.projection.unsettledChildren.length === 0 && this.projection.tools.size === 0,
          'execution_not_idle');
        this.queue.finish(); this.interactions = new AbortController(); this.phase = 'ready';
        return this.dispatchInput(continuation);
      }
      this.projection.cancelTools(); this.phase = 'closing'; await this.closeResources();
      this.publish({ kind: 'interrupted' }); this.phase = 'closed';
      return { interrupted: true, cancelled };
    } catch (error) { await this.fail('interrupt_not_confirmed'); throw error; }
  }
  async history({ offset = 0, limit = 50 } = {}) {
    requireValue(this.query && typeof this.sdk.getSessionMessages === 'function', 'history_unavailable');
    requireValue(Number.isSafeInteger(offset) && offset >= 0 && Number.isSafeInteger(limit) && limit > 0 && limit <= 100);
    return deadline(this.sdk.getSessionMessages(this.config.sessionID, { dir: this.config.cwd, offset, limit }));
  }
  async usage() {
    requireValue(this.query && this.phase !== 'closed', 'session_closed');
    const context = typeof this.query.getContextUsage === 'function' ? await deadline(this.query.getContextUsage()) : null;
    const account = typeof this.query.getUsageInfo === 'function' ? await deadline(this.query.getUsageInfo()) : null;
    return { context: contextView(context), account: usageInfoView(account) };
  }
  async contextUsage() {
    if (typeof this.query?.getContextUsage !== 'function') return null;
    try { return await deadline(this.query.getContextUsage()); } catch { return null; }
  }
  async fail(code) {
    if (this.phase === 'closed') return;
    this.phase = 'closing'; await this.closeResources();
    this.publish({ kind: 'failed', code }); this.phase = 'closed';
  }
  async closeResources() {
    if (!this.closing) this.closing = (async () => {
      this.interactions.abort(); this.queue.cancelPending(); this.input.close();
      try {
        await stopChildren(this.query, this.projection, this.nativeCapabilities);
      } finally {
        try {
          if (this.query) await this.query.close();
          if (this.warm) await this.warm.close();
        } finally {
          await this.processes.close();
          this.policy?.close();
          await this.skillStage?.close();
          this.skillStage = null;
        }
      }
    })();
    return this.closing;
  }
  async close() { this.phase = 'closing'; await this.closeResources(); this.phase = 'closed'; }
}
