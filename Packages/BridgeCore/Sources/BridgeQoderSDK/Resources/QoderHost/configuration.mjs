import { requireValue, object, uuid, absolute, distribution, identifier, text } from './validation.mjs';

export function validateConfiguration(raw) {
  object(raw); requireValue(raw.revision === 1, 'unsupported_host_protocol');
  const config = { revision: 1, distribution: distribution(raw.distribution), cwd: absolute(raw.cwd),
    cliPath: absolute(raw.cliPath), nodePath: absolute(raw.nodePath), sdkRoot: absolute(raw.sdkRoot), sessionID: uuid(raw.sessionID),
    resume: raw.resume === true, persist: raw.persist === true, mode: raw.mode, networkAllowed: raw.networkAllowed === true,
    model: raw.model ? identifier(raw.model) : null, effort: raw.effort ? identifier(raw.effort, 64) : null,
    expectedAccountScope: raw.expectedAccountScope ?? null,
    skills: raw.skills ?? [], selectedSkills: raw.selectedSkills ?? [],
    mcpServers: object(raw.mcpServers ?? {}), proxy: raw.proxy ?? null };
  requireValue(['read-only', 'workspace-write'].includes(config.mode), 'unsupported_task_mode');
  requireValue(Array.isArray(config.skills) && config.skills.length <= 128); config.skills.forEach(value => identifier(value));
  validateSelectedSkills(config.selectedSkills);
  requireValue(config.selectedSkills.length === 0 || (config.skills.length === config.selectedSkills.length
    && config.selectedSkills.every((skill, index) => config.skills[index] === skill.name)),
  'skill_configuration_mismatch');
  requireValue(Object.keys(config.mcpServers).length <= 32);
  requireValue(config.networkAllowed || Object.keys(config.mcpServers).length === 0, 'mcp_network_not_allowed');
  for (const [name, server] of Object.entries(config.mcpServers)) {
    requireValue(/^[a-zA-Z0-9-]+$/u.test(name)); object(server);
    requireValue(['stdio', 'http', 'sse'].includes(server.type ?? 'stdio'), 'unsupported_mcp_transport');
    if (!server.type || server.type === 'stdio') absolute(server.command);
    else { const url = new URL(server.url); requireValue(['https:', 'http:'].includes(url.protocol) && !url.username && !url.password); }
  }
  if (config.proxy) {
    const url = new URL(config.proxy);
    requireValue(['http:', 'https:', 'socks:', 'socks5:'].includes(url.protocol), 'invalid_proxy');
  }
  requireValue(!config.effort || config.model, 'effort_requires_model');
  requireValue(config.expectedAccountScope === null || /^[0-9a-f]{64}$/u.test(config.expectedAccountScope),
    'invalid_account_scope');
  return Object.freeze(config);
}

function validateSelectedSkills(skills) {
  requireValue(Array.isArray(skills) && skills.length <= 16, 'invalid_selected_skills');
  const names = new Set(); let totalBytes = 0;
  for (const skill of skills) {
    object(skill); identifier(skill.name, 128);
    requireValue(['project', 'global'].includes(skill.source)
      && /^[0-9a-f]{64}$/u.test(skill.contentVersion) && !names.has(skill.name), 'invalid_selected_skill');
    names.add(skill.name);
    requireValue(Array.isArray(skill.files) && skill.files.length > 0 && skill.files.length <= 64
      && skill.files.some(file => file?.relativePath === 'SKILL.md'), 'invalid_skill_files');
    const paths = new Set();
    for (const file of skill.files) {
      object(file); text(file.relativePath, 1024);
      const parts = file.relativePath.split('/');
      requireValue(parts.every(part => part && part !== '.' && part !== '..'
        && !part.includes('\\') && !part.includes(':')), 'invalid_skill_path');
      requireValue(!paths.has(file.relativePath), 'duplicate_skill_path'); paths.add(file.relativePath);
      text(file.content, 64 * 1024, true); totalBytes += Buffer.byteLength(file.content);
      requireValue(totalBytes <= 1024 * 1024, 'selected_skill_limit');
    }
  }
}
