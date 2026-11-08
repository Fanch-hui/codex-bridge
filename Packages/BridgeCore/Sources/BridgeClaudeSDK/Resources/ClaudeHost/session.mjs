import { MessageInput, TurnQueue } from './input.mjs';
import { validateConfiguration } from './configuration.mjs';
import { createPolicy } from './policy.mjs';
import { MessageProjection } from './events.mjs';
import { ClaudeProcesses } from './process.mjs';
import { catalog, inspectCLI, loadSDK, sdkVersion, supportsLiteralPrompts } from './sdk.mjs';
import { deadline, HostError, identifier, requireValue, samePath, absolute, uuid } from './validation.mjs';
import { workspaceFileServer } from './workspace-files.mjs';
import { WriteAdmission, hookTimeoutSeconds } from './write-admission.mjs';

export class ClaudeSession {
  constructor(emit, ask, dependencies = {}) {
    this.emit = emit; this.ask = ask; this.loadSDK = dependencies.loadSDK ?? loadSDK;
    this.inspectCLI = dependencies.inspectCLI ?? inspectCLI;
    this.phase = 'new'; this.sequence = 0; this.input = new MessageInput(); this.queue = new TurnQueue();
    this.projection = new MessageProjection(value => this.publish(value), id => this.policy?.takeCompletedWrite(id));
    this.interactions = new AbortController(); this.processes = new ClaudeProcesses();
    this.interactionGeneration = 0;
    this.nativeTools = []; this.toolsObserved = false; this.admission = null;
  }

  publish(value) {
    if (this.phase === 'closed') return;
    requireValue(this.sequence < Number.MAX_SAFE_INTEGER, 'sequence_overflow');
    this.emit({ ...value, sequence: this.sequence++, sessionID: this.config.sessionID,
      taskID: this.config.taskID, runID: this.config.runID });
  }

  async open(raw, { probe = false, catalog: wantsCatalog = false } = {}) {
    requireValue(this.phase === 'new', 'session_already_open');
    this.phase = 'opening';
    this.probe = probe;
    this.config = validateConfiguration(raw, { task: !probe });
    try {
      const inspection = await this.inspectCLI(this.config);
      requireValue(supportsLiteralPrompts(inspection.cliVersion), 'cli_incompatible');
      if (this.config.expectedAccountScope) {
        requireValue(inspection.configScopeDigest === this.config.expectedAccountScope, 'session_account_mismatch');
      }
      if (!inspection.authenticated) {
        requireValue(probe, 'authentication_required');
        this.phase = 'closed';
        return { revision: 1, sdkVersion, ...inspection, models: [], nativeTools: [],
          nativeCapabilities: [], queryMethods: [] };
      }
      const sdk = await this.loadSDK();
      if (this.config.resume && typeof sdk.getSessionInfo === 'function') {
        const previous = await deadline(sdk.getSessionInfo(this.config.sessionID, { dir: this.config.cwd }));
        requireValue(previous?.sessionId === this.config.sessionID && previous.cwd
          && samePath(absolute(previous.cwd), this.config.cwd), 'session_binding_mismatch');
      }
      this.policy = await createPolicy(this.config,
        (value, signal, generation) => this.interact('claude/permission', value, signal, generation),
        (value, signal, generation) => this.interact('claude/question', value, signal, generation));
      if (this.config.writeGate) this.admission = new WriteAdmission((...request) => this.writeRequest(...request));
      if (this.config.isolated) this.workspaceServer = await workspaceFileServer(sdk, this.config.cwd);
      this.warm = await deadline(sdk.startup({ options: this.options(), initializeTimeoutMs: 30000 }), 35000);
      requireValue(this.phase === 'opening', 'session_closed');
      this.query = this.warm.query(this.input);
      requireValue(this.query && typeof this.query.initializationResult === 'function'
        && typeof this.query.close === 'function', 'sdk_incompatible');
      this.pump = this.consume();
      const initialization = await deadline(this.query.initializationResult());
      requireValue(initialization.hooks_applied === true && initialization.hook_on_failure_supported === true,
        'cli_hook_enforcement_unavailable');
      let models = [];
      let catalogUnavailable = false;
      if (wantsCatalog || probe) {
        try {
          requireValue(typeof this.query.supportedModels === 'function', 'catalog_unavailable');
          models = catalog(await deadline(this.query.supportedModels()));
        } catch (error) {
          if (wantsCatalog) throw error;
          catalogUnavailable = true;
        }
      }
      requireValue(this.phase === 'opening', 'session_open_failed');
      this.phase = 'ready';
      return { revision: 1, sessionID: this.config.sessionID, sdkVersion, ...inspection, models,
        nativeTools: this.toolsObserved ? this.nativeTools : this.policy.tools, toolsObserved: this.toolsObserved,
        catalogUnavailable,
        nativeCapabilities: ['read_only_v1', 'approval_v1', 'questions_v1',
          'session_resume_v1', 'stream_input_v1'],
        queryMethods: ['interrupt', 'close', 'supportedModels'].filter(name => typeof this.query[name] === 'function') };
    } catch (error) {
      await this.close();
      throw error;
    }
  }

  interact(method, value, signal, generation = this.interactionGeneration) {
    requireValue(generation === this.interactionGeneration && !this.interactions.signal.aborted,
      'interaction_cancelled');
    const context = this.interactionContext(value, generation);
    if (!signal) return this.ask(method, context, this.interactions.signal);
    const combined = new AbortController();
    const interrupt = () => combined.abort();
    signal.addEventListener('abort', interrupt, { once: true });
    this.interactions.signal.addEventListener('abort', interrupt, { once: true });
    if (signal.aborted || this.interactions.signal.aborted) interrupt();
    const interactionSignal = this.interactions.signal;
    return Promise.resolve().then(() => this.ask(method, context, combined.signal)).finally(() => {
      signal.removeEventListener('abort', interrupt);
      interactionSignal.removeEventListener('abort', interrupt);
    });
  }

  interactionContext(value, generation = this.interactionGeneration) {
    return { ...value, taskID: this.config.taskID, runID: this.config.runID,
      sessionID: this.config.sessionID, interactionGeneration: generation };
  }

  // Acquiring follows the interaction lifecycle; releasing must still go out after an interrupt.
  writeRequest(phase, toolUseID, signal, generation) {
    const value = { phase, toolUseID };
    return phase === 'acquire' ? this.interact('claude/workspaceWrite', value, signal, generation)
      : this.ask('claude/workspaceWrite', this.interactionContext(value));
  }

  options() {
    const config = this.config;
    return {
      cwd: config.cwd, pathToClaudeCodeExecutable: config.cliPath,
      ...(config.resume ? { resume: config.sessionID } : config.sessionID ? { sessionId: config.sessionID } : {}),
      ...(config.model ? { model: config.model } : {}), ...(config.effort ? { effort: config.effort } : {}),
      persistSession: !this.probe, includePartialMessages: true,
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      settingSources: [], autoMemoryEnabled: false, skills: [],
      tools: this.policy.tools, mcpServers: this.workspaceServer
        ? { bridge_workspace: this.workspaceServer } : config.mcpServers, strictMcpConfig: true,
      permissionMode: config.mode === 'read-only' ? 'plan' : 'default',
      spawnClaudeCodeProcess: options => this.processes.spawn(options),
      hooks: {
        PreToolUse: [{ onFailure: 'block', ...(this.admission ? { timeout: hookTimeoutSeconds } : {}),
          hooks: [(input, id, options) => this.preTool(input, id, options)] }],
        PostToolUse: [{ hooks: [async (input, id) => { await this.postTool(input, id, true); return {}; }] }],
        PostToolUseFailure: [{ hooks: [async (input, id) => { await this.postTool(input, id, false); return {}; }] }],
      },
      canUseTool: (tool, input, options) => {
        const bridgeGeneration = this.interactionGeneration;
        const bridgeSignal = this.interactions.signal;
        return this.policy.decide(tool, input, { ...options, bridgeGeneration, bridgeSignal }).then(result => {
          requireValue(bridgeGeneration === this.interactionGeneration && !bridgeSignal.aborted, 'interaction_cancelled');
          return result;
        }).catch(() => ({ behavior: 'deny', message: 'The operation is outside the approved task policy.' }))
          .then(decision => this.admission?.approved(tool, options.toolUseID, decision, options.signal,
            bridgeGeneration) ?? decision);
      },
    };
  }

  async preTool(input, id, options) {
    if (input.tool_input?.run_in_background) {
      return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
        permissionDecisionReason: 'Background execution is unavailable.' } };
    }
    const generation = this.interactionGeneration;
    const result = await this.policy.preTool(input, id, options);
    return this.admission?.preTool(input.tool_name, input.tool_use_id ?? id, result, options?.signal, generation)
      ?? result;
  }

  async postTool(input, id, success) {
    try { await this.policy.completeTool(input, id, success); }
    finally { await this.admission?.release(input?.tool_use_id ?? id); }
  }

  async dispatchInput(value) {
    requireValue(this.phase === 'ready' || this.phase === 'running', 'session_not_accepting_input');
    const id = this.queue.push(value);
    if (this.phase === 'ready') this.beginNext();
    return { accepted: true, inputID: id };
  }

  beginNext() {
    const item = this.queue.take(); if (!item) return;
    this.phase = 'running'; this.turnError = null;
    this.input.send({ type: 'user', uuid: item.id, session_id: this.config.sessionID,
      parent_tool_use_id: null, client_composed: true, priority: 'later', message: { role: 'user', content: [
        { type: 'text', text: item.text }, ...item.images.map(image => ({ type: 'image', source: {
          type: 'base64', media_type: image.mimeType, data: image.data,
        } })),
      ] } });
    this.publish({ kind: 'input_dispatched', inputID: item.id, text: item.text });
  }

  async consume() {
    try {
      for await (const message of this.query) {
        if (message.session_id && this.config.sessionID) {
          requireValue(message.session_id === this.config.sessionID, 'native_session_mismatch');
        }
        if (['assistant', 'stream_event'].includes(message.type) && this.queue.current
          && !this.resultMatchesCurrent(message)) continue;
        if (message.type === 'assistant' && message.error !== undefined) {
          this.turnError = nativeErrorCode(message.error);
          continue;
        }
        if (message.type === 'system' && message.subtype === 'api_retry') {
          this.turnError = nativeErrorCode(message.error) ?? statusErrorCode(message.error_status) ?? this.turnError;
        }
        if (message.type === 'system' && message.subtype === 'init') {
          requireValue(samePath(absolute(message.cwd), this.config.cwd), 'native_workspace_mismatch');
          if (this.config.sessionID) requireValue(message.session_id === this.config.sessionID, 'native_session_mismatch');
          requireValue(Array.isArray(message.tools), 'native_tools_unavailable');
          const required = this.config.mode === 'read-only' ? ['Read', 'AskUserQuestion']
            : ['Read', 'Write', 'Edit', 'AskUserQuestion',
              ...(this.config.networkAllowed && !this.config.isolated ? ['Bash'] : [])];
          requireValue(required.every(tool => message.tools.includes(tool)), 'native_tools_unavailable');
          const sensitive = new Set(['Write', 'Edit', 'NotebookEdit', 'Bash', 'WebSearch', 'WebFetch', 'Agent', 'Task', 'Skill']);
          const configuredMCP = Object.keys(this.config.mcpServers);
          const unexpected = message.tools.some(tool => (sensitive.has(tool) && !this.policy.tools.includes(tool))
            || (typeof tool === 'string' && tool.startsWith('mcp__')
              && !(this.config.isolated && tool === 'mcp__bridge_workspace__list_files')
              && !configuredMCP.some(name => tool.startsWith('mcp__' + name + '__'))));
          requireValue(!unexpected, 'native_tools_outside_policy');
          this.nativeTools = message.tools.filter(tool => typeof tool === 'string' && this.policy.tools.includes(tool)).slice(0, 256);
          this.toolsObserved = true;
        }
        if (this.phase === 'closed') break;
        await this.projection.message(message);
        if (message.type === 'result') await this.result(message);
      }
      if (!['closing', 'closed'].includes(this.phase)) await this.fail('unexpected_stream_end');
    } catch (error) {
      if (!['closing', 'closed'].includes(this.phase)) await this.fail(
        error instanceof HostError ? error.code : 'sdk_execution_failed');
    }
  }

  async result(value) {
    if (value.origin?.kind === 'task-notification') return;
    if (this.queue.current && !this.resultMatchesCurrent(value)) return;
    if (this.phase === 'stopping') {
      this.queue.finish();
      if (this.resultWaiter) { this.resultWaiter(); this.resultWaiter = null; }
      return;
    }
    if (this.phase !== 'running') return;
    this.queue.finish();
    await this.admission?.releaseAll(); // No tool is in flight between turns.
    if (value.subtype !== 'success' || value.is_error) {
      await this.fail(resultErrorCode(value, this.turnError)); return;
    }
    requireValue(this.projection.mainTools.length === 0, 'unfinished_tools');
    const summary = typeof value.result === 'string' ? value.result : '';
    requireValue(summary.trim().length > 0, 'empty_result');
    this.mainResult = { summary: summary.slice(0, 16000), stopReason: 'success' };
    if (this.queue.pending.length > 0) { this.beginNext(); return; }
    requireValue(this.queue.empty, 'unfinished_input');
    this.phase = 'closing';
    this.completion = this.complete();
  }

  resultMatchesCurrent(value) {
    let ids;
    if (value.user_message_uuids !== undefined) {
      requireValue(Array.isArray(value.user_message_uuids) && value.user_message_uuids.length > 0
        && value.user_message_uuids.length <= 64, 'invalid_result_identity');
      ids = value.user_message_uuids.map(uuid);
      if (value.user_message_uuid !== undefined) {
        requireValue(ids.includes(uuid(value.user_message_uuid)), 'invalid_result_identity');
      }
    } else if (value.user_message_uuid !== undefined) {
      ids = [uuid(value.user_message_uuid)];
    } else {
      return true;
    }
    return ids.includes(this.queue.current.id);
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
    this.publish({ kind: 'interactions_cancelled', interactionGeneration: this.interactionGeneration });
    this.interactionGeneration++;
    let completed;
    if (running && continuation) completed = new Promise(resolve => { this.resultWaiter = resolve; });
    try {
      await deadline(this.query.interrupt(), 60000);
      if (completed) await deadline(completed, 60000);
      if (continuation) {
        this.projection.cancelTools();
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

  async fail(code) {
    if (this.phase === 'closed') return;
    this.phase = 'closing';
    try { await this.closeResources(); }
    catch (error) { code = error instanceof HostError ? error.code : 'cleanup_failed'; }
    this.publish({ kind: 'failed', code }); this.phase = 'closed';
  }

  async closeResources() {
    if (!this.closing) this.closing = (async () => {
      this.interactions.abort(); this.queue.cancelPending(); this.input.close();
      let failure;
      try { this.query?.close(); } catch (error) { failure = error; }
      try { this.warm?.close(); } catch (error) { failure ??= error; }
      try { await this.processes.close(); } catch (error) { failure ??= error; }
      // Leases stay held while an owned process may still be writing.
      if (!failure) try { await this.admission?.releaseAll(); } catch (error) { failure = error; }
      try { await this.workspaceServer?.instance.close(); } catch (error) { failure ??= error; }
      this.projection.cancelTools(); this.policy?.close();
      if (failure) throw failure;
    })();
    return this.closing;
  }

  async close() {
    if (this.phase === 'closed') return;
    this.phase = 'closing'; await this.closeResources(); this.phase = 'closed';
  }
}

function nativeErrorCode(value) {
  const allowed = new Set(['authentication_failed', 'oauth_org_not_allowed', 'account_on_hold',
    'verification_required', 'billing_error', 'rate_limit', 'overloaded', 'invalid_request',
    'model_not_found', 'server_error', 'max_output_tokens', 'cloud_credential_error']);
  return allowed.has(value) ? value : null;
}

function statusErrorCode(value) {
  if (value === 401) return 'authentication_failed';
  if (value === 403) return 'permission_denied';
  if (value === 429) return 'rate_limit';
  if (Number.isInteger(value) && value >= 500 && value < 600) return 'server_error';
  return null;
}

function resultErrorCode(value, observed) {
  const startup = {
    gateway_signin_required: 'authentication_required', gateway_access_denied: 'permission_denied',
    cli_version_too_old: 'cli_incompatible', session_held_by_background: 'session_busy',
    cwd_unavailable: 'project_unavailable', sandbox_required_unavailable: 'sandbox_unavailable',
  };
  const terminal = {
    blocking_limit: 'rate_limit', rapid_refill_breaker: 'rate_limit', budget_exhausted: 'budget_exhausted',
    prompt_too_long: 'context_limit', image_error: 'image_error', model_error: 'model_not_found',
    api_error: 'server_error', max_turns: 'maximum_turns',
    structured_output_retry_exhausted: 'structured_output_failed',
  };
  const subtype = { error_max_turns: 'maximum_turns', error_max_budget_usd: 'budget_exhausted',
    error_max_structured_output_retries: 'structured_output_failed' };
  const lookup = (table, key) => typeof key === 'string' && Object.hasOwn(table, key) ? table[key] : undefined;
  const terminalCode = lookup(terminal, value.terminal_reason);
  return lookup(startup, value.startup_failure_reason) ?? statusErrorCode(value.api_error_status)
    ?? (value.terminal_reason === 'api_error' ? undefined : terminalCode)
    ?? lookup(subtype, value.subtype) ?? observed ?? terminalCode ?? 'execution_failed';
}
