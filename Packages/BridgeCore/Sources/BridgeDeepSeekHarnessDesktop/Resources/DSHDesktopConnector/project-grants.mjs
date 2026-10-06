import { realpath } from 'node:fs/promises';
import path from 'node:path';
import { fault, text } from './errors.mjs';

export class ProjectGrants {
  constructor() { this.roots = new Map(); }
  async sync(key, projectPaths) {
    if (!Array.isArray(projectPaths)) throw fault('invalid_request', 'Expected projectPaths');
    const roots = await Promise.all(projectPaths.map(value => realpath(text(value, 'project path'))));
    this.roots.set(key, new Set(roots.map(value => this.canonical(value))));
    return { projectPaths: roots };
  }
  canonical(value) { return process.platform === 'win32' ? path.normalize(value).toLowerCase() : path.normalize(value); }
  async require(key, value) {
    const root = await realpath(text(value, 'project path'));
    if (!this.roots.get(key)?.has(this.canonical(root))) throw fault('project_not_authorized', 'Project has not been registered by the paired Bridge');
    return root;
  }
  async requireSession(key, projectPath, sessionID, native) {
    const root = await this.require(key, projectPath);
    const summary = await native.summary(sessionID);
    if (!summary?.cwd || this.canonical(await realpath(summary.cwd)) !== this.canonical(root)) throw fault('session_project_mismatch', 'Native session belongs to another project');
    return { root, summary };
  }
  revoke(key) { this.roots.delete(key); }
}
