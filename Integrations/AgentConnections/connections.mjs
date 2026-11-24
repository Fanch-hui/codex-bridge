import { edit, inspect, reverse } from './editor.mjs';
import path from 'node:path';

const providerID = 'codex_bridge';
const codexHybridProviderID = 'codex_bridge_hybrid';
const set = (path, value) => ({ path, after: { exists: true, value } });
const remove = path => ({ path, after: { exists: false } });
// Codex Desktop stores the picked model in `model`; revert puts back the original when the field
// still names a Bridge gateway model, which would no longer resolve once the provider is gone.
const gatewayModelSlugPrefix = 'bridge.';
const reclaimModel = (source, path) => {
  const state = inspect(source, 'toml', path);
  return { path, after: state, reclaimPrefix: gatewayModelSlugPrefix };
};

const effortLevels = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

// Optional per-model limits from the gateway: { [modelID]: { context?, output?, efforts? } }, where
// efforts are the reasoning levels the gateway accepts as `reasoning_effort` for that model.
function readLimits(value, modelIDs) {
  if (value === undefined) return {};
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_model');
  const valid = number => number === undefined || (Number.isSafeInteger(number) && number > 0);
  const validEfforts = efforts => efforts === undefined || (Array.isArray(efforts) && efforts.length > 0 &&
    efforts.every(effort => effortLevels.includes(effort)) && new Set(efforts).size === efforts.length);
  for (const [id, limit] of Object.entries(value)) {
    if (!modelIDs.includes(id) || !limit || typeof limit !== 'object' || Array.isArray(limit) ||
        Object.keys(limit).some(key => !['context', 'output', 'efforts'].includes(key)) ||
        !valid(limit.context) || !valid(limit.output) || !validEfforts(limit.efforts)) throw new Error('invalid_model');
  }
  return value;
}

// Pi: only the declared levels are selectable; `off` stays unavailable as it would only omit the field.
function piReasoning(efforts) {
  if (!efforts) return {};
  return { reasoning: true, thinkingLevelMap: Object.fromEntries(['off', ...effortLevels]
    .map(level => [level, efforts.includes(level) ? level : null])) };
}

// OpenCode sends a variant's `reasoningEffort` as the OpenAI-compatible `reasoning_effort`.
function openCodeVariants(agent, efforts) {
  if (agent === 'opencode1') {
    return efforts ? { reasoning: true, variants: Object.fromEntries(efforts.map(effort => [effort, { reasoningEffort: effort }])) } : {};
  }
  return { variants: (efforts ?? []).map(effort => ({ id: effort, settings: { reasoningEffort: effort } })) };
}

// Compaction leaves room for one response, mirroring the workbench rule.
function autoCompactAt({ context, output }) {
  return context - Math.min(output ?? 19000, Math.floor(context / 2));
}

function modelChanges(agent, model, source) {
  if (agent === 'claude_desktop') throw new Error('unsupported_agent');
  if (!model || typeof model.endpoint !== 'string' || typeof model.model !== 'string' || !model.model) {
    throw new Error('invalid_model');
  }
  const url = new URL(model.endpoint);
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      !url.port || url.username || url.password || url.search || url.hash ||
      !['/v1', '/v1/'].includes(url.pathname)) throw new Error('invalid_endpoint');
  const compatibility = model.compatibility === undefined ? {} : model.compatibility;
  let allowed = [];
  if (agent === 'codex') allowed = ['disableWebSearch', 'disableMultiAgent', 'preserveOfficialLogin'];
  if (agent === 'codex_desktop') allowed = ['disableWebSearch', 'disableMultiAgent', 'preserveOfficialLogin'];
  if (agent === 'claude') allowed = ['disableThinking', 'preserveOfficialLogin'];
  if (!compatibility || typeof compatibility !== 'object' || Array.isArray(compatibility) ||
      Object.entries(compatibility).some(([key, value]) => !allowed.includes(key) || typeof value !== 'boolean')) {
    throw new Error('invalid_compatibility');
  }
  const hybrid = agent === 'codex_desktop' && compatibility.preserveOfficialLogin === true;
  if (!hybrid && (typeof model.token !== 'string' || !model.token)) throw new Error('invalid_model');
  const modelIDs = model.models ?? [model.model];
  if (!Array.isArray(modelIDs) || !modelIDs.includes(model.model) ||
        modelIDs.some(id => typeof id !== 'string' || !id) || new Set(modelIDs).size !== modelIDs.length) {
    throw new Error('invalid_model');
  }
  const limits = readLimits(model.limits, modelIDs);
  const selectedLimit = limits[model.model];
  const codexLimits = selectedLimit?.context ? {
    model_context_window: selectedLimit.context, model_auto_compact_token_limit: autoCompactAt(selectedLimit)
  } : {};
  if (hybrid) {
    if (compatibility.disableWebSearch || compatibility.disableMultiAgent ||
        typeof model.credentialCommand !== 'string' || !path.isAbsolute(model.credentialCommand) ||
        typeof model.credentialClientID !== 'string' || !model.credentialClientID) {
      throw new Error('invalid_compatibility');
    }
    const changes = [
      set(['model_provider'], codexHybridProviderID),
      set(['model_providers', codexHybridProviderID], {
        name: 'Codex Bridge', base_url: model.endpoint,
        model_catalog_url: new URL('/codex/models', url).href,
        wire_api: 'responses', requires_openai_auth: true, supports_websockets: true,
        capabilities: { remote_compaction: 'unsupported' },
        gateway_oauth: {
          delivery: { kind: 'header', name: 'X-Bridge-Gateway-Token', scheme: 'Bearer' },
          credential_export: {
            command: model.credentialCommand,
            args: ['--export-codex-gateway-token', model.credentialClientID],
          },
        },
      }),
    ];
    if (inspect(source, 'toml', ['model_catalog_json']).exists) changes.push(remove(['model_catalog_json']));
    changes.push(reclaimModel(source, ['model']));
    const profile = inspect(source, 'toml', ['profile']);
    if (profile.exists) {
      if (typeof profile.value !== 'string' || !profile.value) throw new Error('invalid_configuration');
      const modelPath = ['profiles', profile.value, 'model'];
      if (inspect(source, 'toml', modelPath).exists) changes.push(reclaimModel(source, modelPath));
      const providerPath = ['profiles', profile.value, 'model_provider'];
      if (inspect(source, 'toml', providerPath).exists) changes.push(set(providerPath, codexHybridProviderID));
      const catalogPath = ['profiles', profile.value, 'model_catalog_json'];
      if (inspect(source, 'toml', catalogPath).exists) changes.push(remove(catalogPath));
    }
    return changes;
  }
  if (agent === 'codex' || agent === 'codex_desktop') {
    const provider = {
      name: 'Codex Bridge', base_url: model.endpoint, wire_api: 'responses',
      experimental_bearer_token: model.token, requires_openai_auth: false,
    };
    if (agent === 'codex' && compatibility.preserveOfficialLogin) {
      const profile = { model: model.model, model_provider: providerID, ...codexLimits };
      if (compatibility.disableWebSearch) profile.web_search = 'disabled';
      if (compatibility.disableMultiAgent) profile.features = { multi_agent: false };
      return [
        set(['model_providers', providerID], provider),
        set(['profiles', providerID], profile),
      ];
    }
    const changes = [
      set(['model'], model.model), set(['model_provider'], providerID),
      set(['model_providers', providerID], provider),
    ];
    if (agent === 'codex_desktop') {
      // The desktop model picker lists only the local catalog, so point it at Bridge's catalog
      // of the authorized models; per-model context windows live in that catalog.
      if (typeof model.catalogPath !== 'string' || !path.isAbsolute(model.catalogPath)) {
        throw new Error('invalid_model');
      }
      changes.push(set(['model_catalog_json'], model.catalogPath));
      const profile = inspect(source, 'toml', ['profile']);
      if (profile.exists) {
        if (typeof profile.value !== 'string' || !profile.value) throw new Error('invalid_configuration');
        for (const key of ['model_provider', 'model_catalog_json']) {
          const profilePath = ['profiles', profile.value, key];
          if (inspect(source, 'toml', profilePath).exists) {
            changes.push(set(profilePath, key === 'model_provider' ? providerID : model.catalogPath));
          }
        }
      }
    } else {
      for (const [key, value] of Object.entries(codexLimits)) changes.push(set([key], value));
    }
    if (compatibility.disableWebSearch) changes.push(set(['web_search'], 'disabled'));
    if (compatibility.disableMultiAgent) changes.push(set(['features', 'multi_agent'], false));
    return changes;
  }
  if (agent === 'claude') {
    const changes = [
      set(['env', 'ANTHROPIC_BASE_URL'], url.origin),
    ];
    if (compatibility.preserveOfficialLogin) {
      const headerLine = `X-Codex-Bridge-Token: ${model.token}`;
      const existingCustom = inspect(source, 'json', ['env', 'ANTHROPIC_CUSTOM_HEADERS']);
      let customHeaders = headerLine;
      if (existingCustom.exists) {
        if (typeof existingCustom.value !== 'string') throw new Error('invalid_configuration');
        const kept = existingCustom.value
          .split(/\r?\n/)
          .filter(line => line.trim() && !/^x-codex-bridge-token\s*:/i.test(line.trim()));
        customHeaders = [...kept, headerLine].join('\n');
      }
      changes.push(set(['env', 'ANTHROPIC_CUSTOM_HEADERS'], customHeaders));
    } else {
      changes.push(
        set(['env', 'ANTHROPIC_AUTH_TOKEN'], model.token),
        set(['env', 'ANTHROPIC_MODEL'], model.model),
      );
    }
    if (model.models) {
      const path = ['modelPicker', 'options'];
      const parent = inspect(source, 'json', ['modelPicker']);
      if (parent.exists && (!parent.value || typeof parent.value !== 'object' || Array.isArray(parent.value))) throw new Error('invalid_configuration');
      const existing = inspect(source, 'json', path);
      const rows = existing.exists ? existing.value : [];
      if (!Array.isArray(rows)) throw new Error('invalid_configuration');
      const added = modelIDs.filter(id => !rows.some(row => row?.model === id));
      if (added.length) {
        const options = [...rows, ...added.map(id => ({ model: id }))];
        changes.push(parent.exists ? set(path, options) : set(['modelPicker'], { options }));
      }
    }
    if (compatibility.disableThinking) changes.push(set(['env', 'CLAUDE_CODE_DISABLE_THINKING'], '1'));
    return changes;
  }
  if (agent === 'pi') return [
    set(['providers', providerID], {
      baseUrl: model.endpoint, api: 'openai-completions', apiKey: model.token,
      models: modelIDs.map(id => ({ id,
        ...(limits[id]?.context ? { contextWindow: limits[id].context } : {}),
        ...(limits[id]?.output ? { maxTokens: limits[id].output } : {}),
        ...piReasoning(limits[id]?.efforts) })),
    }),
  ];
  if (agent === 'opencode1' || agent === 'opencode2') {
    const models = Object.fromEntries([model.model, ...modelIDs.filter(id => id !== model.model)]
      .map(id => {
        const key = id === model.model ? 'bridge' : `m_${Buffer.from(id, 'utf8').toString('base64url')}`;
        // OpenCode 1.x requires both values in `limit`; 2.x model limits are not written.
        const limit = limits[id]?.context && limits[id]?.output
          ? { limit: { context: limits[id].context, output: limits[id].output } } : {};
        const variants = openCodeVariants(agent, limits[id]?.efforts);
        return [key, agent === 'opencode1'
          ? { id, name: id, ...limit, ...variants }
          : { modelID: id, name: id, ...variants }];
      }));
    if (agent === 'opencode1') return [
      set(['model'], `${providerID}/bridge`),
      set(['provider', providerID], {
        npm: '@ai-sdk/openai-compatible', name: 'Codex Bridge',
        options: { baseURL: model.endpoint, apiKey: model.token }, models,
      }),
    ];
    return [
      set(['model'], `${providerID}/bridge`),
      set(['providers', providerID], {
        package: '@opencode/ai/providers/openai-compatible', name: 'Codex Bridge',
        settings: { baseURL: model.endpoint, apiKey: model.token }, models,
      }),
    ];
  }
  throw new Error('unsupported_agent');
}

function mcpChanges(agent, mcp) {
  if (!mcp || typeof mcp.command !== 'string' || !mcp.command || !Array.isArray(mcp.args) ||
      mcp.args.some(arg => typeof arg !== 'string')) throw new Error('invalid_mcp');
  if (agent === 'codex' || agent === 'codex_desktop') return [set(['mcp_servers', providerID], {
    command: mcp.command, args: mcp.args,
  })];
  if (agent === 'pi' || agent === 'claude_desktop') return [set(['mcpServers', providerID], {
    command: mcp.command, args: mcp.args,
  })];
  if (agent === 'claude') return [set(['mcpServers', providerID], {
    type: 'stdio', command: mcp.command, args: mcp.args,
  })];
  if (agent === 'opencode1') return [set(['mcp', providerID], {
    type: 'local', command: [mcp.command, ...mcp.args], enabled: true,
  })];
  if (agent === 'opencode2') return [set(['mcp', 'servers', providerID], {
    type: 'local', command: [mcp.command, ...mcp.args], disabled: false,
  })];
  throw new Error('unsupported_agent');
}

function configurationFormat(agent) {
  if (agent === 'codex' || agent === 'codex_desktop') return 'toml';
  if (agent === 'claude' || agent === 'claude_desktop') return 'json';
  if (agent === 'opencode1' || agent === 'opencode2' || agent === 'pi') return 'jsonc';
  throw new Error('unsupported_agent');
}

const isReclaim = change => change?.reclaimPrefix !== undefined;
const samePath = (left, right) => left.length === right.length && left.every((part, i) => part === right[i]);

export function prepare({ agent, purpose, content, model, mcp, previousChanges }) {
  const format = configurationFormat(agent);
  let source = content === null ? (format === 'toml' ? '' : '{}\n') : content;
  if (typeof source !== 'string' || Buffer.byteLength(source) > 2 * 1024 * 1024) {
    throw new Error('invalid_configuration');
  }
  if (previousChanges !== undefined) {
    if (!Array.isArray(previousChanges)) throw new Error('invalid_configuration');
    // The picked model stays as it is through an update; only the final revert reclaims it.
    const restored = reverse(source, format, previousChanges.filter(change => !isReclaim(change)));
    if (restored.conflicts) return restored;
    source = restored.content;
  }
  const changes = purpose === 'model' ? modelChanges(agent, model, source)
    : purpose === 'mcp' ? mcpChanges(agent, mcp) : undefined;
  if (!changes) throw new Error('unsupported_purpose');
  for (const change of changes) {
    const earlier = isReclaim(change) &&
      previousChanges?.find(previous => isReclaim(previous) && samePath(previous.path, change.path));
    change.before = earlier ? earlier.before : inspect(source, format, change.path);
    if (change.path.some(part => part === providerID || part === codexHybridProviderID) &&
        change.before.exists) throw new Error('owned_name_in_use');
  }
  const fields = [...(previousChanges ?? []), ...changes]
    .filter(change => !isReclaim(change))
    .map(change => change.path)
    .filter((path, index, paths) => paths.findIndex(other => samePath(other, path)) === index);
  return { content: edit(source, format, changes), changes, fields };
}

export function revert({ agent, content, changes, keepDrifted }) {
  if (typeof content !== 'string' || !Array.isArray(changes) ||
      (keepDrifted !== undefined && typeof keepDrifted !== 'boolean')) throw new Error('invalid_configuration');
  return reverse(content, configurationFormat(agent), changes, { keepDrifted });
}
