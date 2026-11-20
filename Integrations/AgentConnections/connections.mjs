import { edit, inspect, reverse } from './editor.mjs';

const providerID = 'codex_bridge';
const set = (path, value) => ({ path, after: { exists: true, value } });

function modelChanges(agent, model, source) {
  if (agent === 'claude_desktop') throw new Error('unsupported_agent');
  if (!model || typeof model.endpoint !== 'string' || typeof model.model !== 'string' ||
      typeof model.token !== 'string' || !model.model || !model.token) throw new Error('invalid_model');
  const url = new URL(model.endpoint);
  if (url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      !url.port || url.username || url.password || url.search || url.hash ||
      !['/v1', '/v1/'].includes(url.pathname)) throw new Error('invalid_endpoint');
  const compatibility = model.compatibility === undefined ? {} : model.compatibility;
  let allowed = [];
  if (agent === 'codex') allowed = ['disableWebSearch', 'disableMultiAgent', 'preserveOfficialLogin'];
  if (agent === 'codex_desktop') allowed = ['disableWebSearch', 'disableMultiAgent'];
  if (agent === 'claude') allowed = ['disableThinking', 'preserveOfficialLogin'];
  if (!compatibility || typeof compatibility !== 'object' || Array.isArray(compatibility) ||
      Object.entries(compatibility).some(([key, value]) => !allowed.includes(key) || typeof value !== 'boolean')) {
    throw new Error('invalid_compatibility');
  }
  const modelIDs = model.models ?? [model.model];
  if (!Array.isArray(modelIDs) || !modelIDs.includes(model.model) ||
        modelIDs.some(id => typeof id !== 'string' || !id) || new Set(modelIDs).size !== modelIDs.length) {
    throw new Error('invalid_model');
  }
  if (agent === 'codex' || agent === 'codex_desktop') {
    const provider = {
      name: 'Codex Bridge', base_url: model.endpoint, wire_api: 'responses',
      experimental_bearer_token: model.token, requires_openai_auth: false,
    };
    if (agent === 'codex' && compatibility.preserveOfficialLogin) {
      const profile = { model: model.model, model_provider: providerID };
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
      models: modelIDs.map(id => ({ id })),
    }),
  ];
  if (agent === 'opencode1' || agent === 'opencode2') {
    const models = Object.fromEntries([model.model, ...modelIDs.filter(id => id !== model.model)]
      .map(id => {
        const key = id === model.model ? 'bridge' : `m_${Buffer.from(id, 'utf8').toString('base64url')}`;
        return [key, agent === 'opencode1'
          ? { id, name: id }
          : { modelID: id, name: id, variants: [] }];
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

export function prepare({ agent, purpose, content, model, mcp, previousChanges }) {
  const format = configurationFormat(agent);
  let source = content === null ? (format === 'toml' ? '' : '{}\n') : content;
  if (typeof source !== 'string' || Buffer.byteLength(source) > 2 * 1024 * 1024) {
    throw new Error('invalid_configuration');
  }
  if (previousChanges !== undefined) {
    if (!Array.isArray(previousChanges)) throw new Error('invalid_configuration');
    const restored = reverse(source, format, previousChanges);
    if (restored.conflicts) return restored;
    source = restored.content;
  }
  const changes = purpose === 'model' ? modelChanges(agent, model, source)
    : purpose === 'mcp' ? mcpChanges(agent, mcp) : undefined;
  if (!changes) throw new Error('unsupported_purpose');
  for (const change of changes) {
    change.before = inspect(source, format, change.path);
    if (change.path.includes(providerID) && change.before.exists) throw new Error('owned_name_in_use');
  }
  const fields = [...(previousChanges ?? []), ...changes]
    .map(change => change.path)
    .filter((path, index, paths) => paths.findIndex(other =>
      other.length === path.length && other.every((part, i) => part === path[i])) === index);
  return { content: edit(source, format, changes), changes, fields };
}

export function revert({ agent, content, changes }) {
  if (typeof content !== 'string' || !Array.isArray(changes)) throw new Error('invalid_configuration');
  return reverse(content, configurationFormat(agent), changes);
}
