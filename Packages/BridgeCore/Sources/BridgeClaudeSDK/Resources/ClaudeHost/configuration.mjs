import { absolute, identifier, object, requireValue, uuid } from './validation.mjs';

export function validateConfiguration(raw, { task = true } = {}) {
  object(raw);
  requireValue(raw.revision === 1, 'unsupported_host_protocol');
  const config = {
    cwd: absolute(raw.cwd), cliPath: absolute(raw.cliPath),
    sessionID: raw.sessionID == null && !task ? null : uuid(raw.sessionID),
    resume: raw.resume === true, mode: raw.mode ?? 'read-only',
    networkAllowed: raw.networkAllowed === true, autoApprove: raw.autoApprove === true,
    nativeSubagentsAllowed: raw.nativeSubagentsAllowed === true,
    isolated: raw.isolated === true, writeGate: raw.writeGate === true,
    model: raw.model == null ? null : identifier(raw.model),
    effort: raw.effort == null ? null : identifier(raw.effort, 64),
    expectedAccountScope: raw.expectedAccountScope ?? null,
    mcpServers: object(raw.mcpServers ?? {}),
    selectedSkills: raw.selectedSkills ?? [],
    taskID: raw.taskID == null && !task ? null : identifier(raw.taskID),
    runID: raw.runID == null && !task ? null : identifier(raw.runID),
  };
  requireValue(['read-only', 'workspace-write'].includes(config.mode), 'unsupported_task_mode');
  requireValue(raw.nativeSubagentsAllowed === undefined || typeof raw.nativeSubagentsAllowed === 'boolean',
    'invalid_subagent_policy');
  requireValue(raw.writeGate === undefined || typeof raw.writeGate === 'boolean', 'invalid_write_gate');
  requireValue(!config.networkAllowed || config.mode === 'workspace-write', 'unsupported_task_mode');
  requireValue(!config.effort || config.model, 'effort_requires_model');
  requireValue(config.expectedAccountScope === null || /^[0-9a-f]{64}$/u.test(config.expectedAccountScope),
    'invalid_account_scope');
  requireValue(Array.isArray(config.selectedSkills) && config.selectedSkills.length === 0,
    'selected_skills_unavailable');
  const entries = Object.entries(config.mcpServers);
  requireValue(entries.length <= 32 && (config.networkAllowed || entries.length === 0), 'mcp_network_not_allowed');
  requireValue(!config.isolated || entries.length === 0, 'isolated_mcp_unavailable');
  for (const [name, server] of entries) {
    requireValue(/^[a-zA-Z0-9-]+$/u.test(name)); object(server);
    const type = server.type ?? 'stdio';
    requireValue(['stdio', 'http', 'sse'].includes(type), 'unsupported_mcp_transport');
    if (type === 'stdio') absolute(server.command);
    else {
      const url = new URL(server.url);
      requireValue(['https:', 'http:'].includes(url.protocol) && !url.username && !url.password, 'invalid_mcp_url');
    }
  }
  return Object.freeze(config);
}
