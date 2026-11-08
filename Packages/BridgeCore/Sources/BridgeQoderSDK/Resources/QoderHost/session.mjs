import { MessageInput, TurnQueue } from './input.mjs';
import { validateConfiguration } from './configuration.mjs';
export { validateConfiguration } from './configuration.mjs';
import { createPolicy } from './policy.mjs';
import { MessageProjection, stopChildren } from './events.mjs';
import { catalog, modelPolicy, validateSelection } from './models.mjs';
import { loadSDK, authentication, isSDKAuthenticationError, validateSDKQuery, sdkPermissionMode, sdkLifecycle } from './sdk.mjs';
import { SDKProcessOwner } from './process.mjs';
import { queryAccountScope, accountScopeFromQuery } from './account-scope.mjs';
import { stageSelectedSkills } from './skill-resources.mjs';
import { usageStatistics, contextView, usageInfoView } from './usage.mjs';
import { requireValue, absolute, identifier, deadline, HostError, samePath } from './validation.mjs';
import { WriteAdmission, hookTimeoutSeconds } from './write-admission.mjs';

export class QoderSession {
  constructor(emit, ask, loader = loadSDK, lifecycle = sdkLifecycle) {
    this.emit = emit; this.ask = ask; this.loader = loader; this.lifecycle = lifecycle; this.phase = 'new';
    this.input = new MessageInput(); this.queue = new TurnQueue();
    this.projection = new MessageProjection(value => this.publish(value));
    this.interactions = new AbortController(); this.closing = null; this.resultWaiter = null;
    this.sequence = 0; this.query = null; this.warm = null; this.nativeCapabilities = new Set();
    this.nativeTools = new Set(); this.nativeSkills = []; this.mcpServers = [];
    this.nativeInitialization = new Promise(resolve => { this.resolveNativeInitialization = resolve; });
    this.processes = new SDKProcessOwner(); this.admission = null;
  }
  publish(value) {
    if (this.phase === 'closed') return;
    requireValue(this.sequence < Number.MAX_SAFE_INTEGER, 'sequence_overflow');
    this.emit({ ...value, sequence: this.sequence++, sessionID: this.config?.sessionID,
      distribution: this.config?.distribution });
  }
  async open(raw) {
    requireValue(this.phase === 'new', 'session_already_open'); this.phase = 'opening';
    this.openingWork = new Promise(resolve => { this.finishOpeningWork = resolve; });
    try {
      this.config = validateConfiguration(raw);
      const loaded = await this.loader(this.config);
      requireValue(this.phase === 'opening', 'session_closed');
      const lease = await this.lifecycle.acquire(loaded.sdk);
      if (this.phase !== 'opening') { await lease.release(); throw new HostError('session_closed'); }
      this.sdkLease = lease; this.sdk = loaded.sdk;
      this.skillStage = await stageSelectedSkills(this.config.selectedSkills);
      requireValue(this.phase === 'opening', 'session_closed');
      if (this.config.resume) {
        this.accountScopeDigest = await queryAccountScope(this.sdk, this.config);
        requireValue(this.phase === 'opening', 'session_closed');
        requireValue(!this.config.expectedAccountScope || this.config.expectedAccountScope === this.accountScopeDigest,
          'session_account_mismatch');
        const previous = await deadline(this.sdk.getSessionInfo(this.config.sessionID, { dir: this.config.cwd }));
        requireValue(this.phase === 'opening', 'session_closed');
        requireValue(previous?.sessionId === this.config.sessionID && previous.cwd
          && samePath(absolute(previous.cwd), this.config.cwd), 'session_binding_mismatch');
      }
      this.policy = await createPolicy(this.config, (value, signal) => this.ask('qoder/permission', value,
        AbortSignal.any([signal ?? new AbortController().signal, this.interactions.signal])),
      (value, signal) => this.ask('qoder/question', value,
        AbortSignal.any([signal ?? new AbortController().signal, this.interactions.signal])),
      { additionalReadRoots: this.skillStage ? [this.skillStage.root] : [] });
      requireValue(this.phase === 'opening', 'session_closed');
      if (this.config.writeGate) this.admission = new WriteAdmission((...request) => this.writeRequest(...request));
      const options = this.options();
      this.startup = Promise.resolve().then(() => this.sdk.startup({ options, initializeTimeoutMs: 30000 }))
        .then(warm => { this.warm = warm; return warm; });
      await deadline(this.startup, 35000);
      requireValue(this.phase === 'opening', 'session_closed');
      this.query = this.warm.query(this.input); validateSDKQuery(this.query);
      this.pump = this.consume();
      const initialization = await deadline(this.query.initializationResult());
      await deadline(this.nativeInitialization, 30000);
      this.nativeCapabilities = new Set(initialization.capabilities ?? this.nativeCapabilities);
      requireValue(this.config.selectedSkills.every(skill => this.nativeSkills.includes(skill.name)),
        'selected_skill_unavailable');
      requireValue(this.config.selectedSkills.length === 0 || this.nativeCapabilities.has('selected_skills_v1'),
        'selected_skills_unavailable');
      const [accountScope, nativeModels] = await Promise.all([
        accountScopeFromQuery(this.query, this.config), deadline(this.query.getAvailableModels()),
      ]);
      requireValue(!this.config.expectedAccountScope || this.config.expectedAccountScope === accountScope,
        'session_account_mismatch');
      this.accountScopeDigest = accountScope;
      const models = catalog(nativeModels);
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
      this.finishOpeningWork?.(); this.finishOpeningWork = null;
      try { await this.close(); }
      catch (cleanup) { throw new HostError('process_exit_unconfirmed', new AggregateError([error, cleanup])); }
      if (this.authenticationExpired || isSDKAuthenticationError(error)) throw new HostError('authentication_required');
      throw error;
    } finally {
      this.finishOpeningWork?.(); this.finishOpeningWork = null;
    }
  }
  // Acquiring follows the interaction lifecycle; releasing must still go out after an interrupt.
  writeRequest(phase, toolUseID, signal) {
    const value = { phase, toolUseID };
    return this.ask('qoder/workspaceWrite', value, phase === 'acquire'
      ? AbortSignal.any([signal ?? new AbortController().signal, this.interactions.signal]) : undefined);
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
      strictMcpConfig: true, permissionMode: sdkPermissionMode(config.permissionMode), maxTurns: 100,
      ...(config.proxy ? { proxy: config.proxy } : {}),
      hooks: { PreToolUse: [{ ...(this.admission ? { timeout: hookTimeoutSeconds } : {}),
        hooks: [(input, id, options) => this.preTool(input, id, options)] }],
      PostToolUse: [{ hooks: [async (input, id) => { await this.postTool(input, id); return {}; }] }],
      PostToolUseFailure: [{ hooks: [async (input, id) => { await this.postTool(input, id); return {}; }] }] },
      canUseTool: (tool, input, options) => this.policy.decide(tool, input, options).catch(() => ({
        behavior: 'deny', message: 'The operation is outside the approved task policy.' }))
        .then(decision => this.admission?.approved(tool, options.toolUseID, decision, options.signal) ?? decision),
    };
  }
  async preTool(input, id, options) {
    const deny = reason => ({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
      permissionDecisionReason: reason } });
    if (input.tool_input?.run_in_background) {
      if (!this.nativeCapabilities.has('background_tasks_v1')) return deny('Background task control is unavailable.');
      // A detached command would keep writing after its tool call, and so its lease, has ended.
      if (this.admission && input.tool_name !== 'Agent') return deny('Background execution is unavailable while the project is shared.');
    }
    const result = await this.policy.preTool(input, id, options);
    return this.admission?.preTool(input.tool_name, input.tool_use_id ?? id, result, options?.signal) ?? result;
  }
  async postTool(input, id) {
    this.policy.finishTool(id);
    await this.admission?.release(input?.tool_use_id ?? id);
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
          this.resolveNativeInitialization?.(); this.resolveNativeInitialization = null;
        }
        if (this.phase === 'closed') break;
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
    if (value.origin?.kind === 'task-notification') return;
    const context = await this.contextUsage();
    if (this.phase === 'stopping') {
      this.queue.finish();
      if (this.resultWaiter) { this.resultWaiter(); this.resultWaiter = null; }
      return;
    }
    if (this.phase !== 'running') return;
    const statistics = usageStatistics(value, context);
    if (statistics) this.publish({ kind: 'usage_statistics', statistics });
    this.queue.finish();
    await this.admission?.releaseAll(); // No tool is in flight between turns.
    if (value.subtype !== 'success' || value.is_error) { await this.fail('qoder_incomplete_result'); return; }
    requireValue(this.projection.mainTools.length === 0, 'unfinished_tools');
    const summary = typeof value.result === 'string' ? value.result : '';
    requireValue(summary.trim().length > 0, 'empty_result');
    this.mainResult = { summary: summary.slice(0, 16000), stopReason: 'success' };
    if (this.queue.pending.length > 0) { this.beginNext(); return; }
    requireValue(this.queue.empty, 'unfinished_input');
    this.phase = 'closing';
    // Keep consuming native stop notifications while cleanup confirms process exit.
    this.completion = this.complete();
  }
  async complete() {
    try {
      await this.closeResources();
      this.publish({ kind: 'completed', ...this.mainResult });
    } catch (error) {
      this.publish({ kind: 'failed', code: error instanceof HostError ? error.code : 'cleanup_failed' });
    }
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
        await this.admission?.releaseAll();
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
    this.phase = 'closing';
    try { await this.closeResources(); }
    catch (error) { code = error instanceof HostError ? error.code : 'cleanup_failed'; }
    this.publish({ kind: 'failed', code }); this.phase = 'closed';
  }
  cleanupDiagnostic(stage, error) {
    const code = error instanceof HostError ? error.code : 'cleanup_failed';
    this.publish({ kind: 'tool', key: 'qoder-cleanup-' + stage, name: 'Qoder 清理',
      status: 'failed', output: stage + ': ' + code });
  }
  async closeResources() {
    if (!this.closing) this.closing = (async () => {
      this.interactions.abort(); this.queue.cancelPending(); this.input.close();
      // Opening can include an account preflight as well as SDK prewarming.
      await this.openingWork;
      try { await this.startup; } catch {}
      for (const [stage, close] of [
        ['background', () => stopChildren(this.query, this.projection, this.nativeCapabilities)],
        ['query', () => this.query?.close()], ['startup', () => this.warm?.close()],
      ]) {
        try { await close(); } catch (error) { this.cleanupDiagnostic(stage, error); }
      }
      // A terminal event is safe only after every owned process has exited.
      const failures = [];
      for (const close of [() => this.processes.close(), () => this.sdkLease?.release(true)]) {
        try { await close(); } catch (error) { failures.push(error); }
      }
      // Leases stay held while an owned process may still be writing.
      if (failures.length === 0) {
        try { await this.admission?.releaseAll(); } catch (error) { failures.push(error); }
      }
      this.projection.cancelTools(); this.policy?.close();
      try { await this.skillStage?.close(); }
      catch (error) { this.cleanupDiagnostic('skills', error); }
      this.skillStage = null;
      if (failures.length === 1) throw failures[0];
      if (failures.length > 1) throw new HostError('process_exit_unconfirmed', new AggregateError(failures));
    })();
    return this.closing;
  }
  async close() { this.phase = 'closing'; await this.closeResources(); this.phase = 'closed'; }
}
