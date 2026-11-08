import { spawn } from 'node:child_process';
import { realpathSync, statSync } from 'node:fs';
import { HostError } from './validation.mjs';

export function spawnClaude(command, args, options) {
  if (process.env.CODEX_BRIDGE_CLAUDE_ISOLATED === '1') {
    if (process.platform !== 'darwin') throw new HostError('isolation_unavailable');
    const profile = process.env.CODEX_BRIDGE_CLAUDE_ISOLATION_PROFILE;
    const workspace = process.env.CODEX_BRIDGE_CLAUDE_WORKSPACE;
    if (!profile?.startsWith('(version 1)') || !profile.includes('(deny file-write*)')
      || !profile.includes('(deny process-fork)') || profile.length > 65536
      || !workspace || realpathSync(options.cwd ?? process.cwd()) !== workspace
      || !Array.isArray(args) || args.length > 512
      || args.some(value => typeof value !== 'string' || value.includes('\0'))
      || args.reduce((size, value) => size + Buffer.byteLength(value), 0) > 1048576) {
      throw new HostError('isolation_launch_invalid');
    }
    const childEnvironment = options.env ?? process.env;
    for (const key of ['HOME', 'TMPDIR', 'TMP', 'TEMP', 'XDG_CACHE_HOME', 'XDG_CONFIG_HOME',
      'XDG_DATA_HOME', 'XDG_STATE_HOME', 'CLAUDE_CONFIG_DIR', 'CODEX_BRIDGE_CLAUDE_ISOLATED',
      'CODEX_BRIDGE_CLAUDE_ISOLATION_PROFILE', 'CODEX_BRIDGE_CLAUDE_WORKSPACE',
      'CODEX_BRIDGE_CLAUDE_CLI_ARTIFACT', 'CODEX_BRIDGE_CLAUDE_NODE_ARTIFACT']) {
      if (childEnvironment[key] !== process.env[key]) throw new HostError('isolation_launch_invalid');
    }
    const cli = isolationArtifact(process.env.CODEX_BRIDGE_CLAUDE_CLI_ARTIFACT);
    const node = isolationArtifact(process.env.CODEX_BRIDGE_CLAUDE_NODE_ARTIFACT);
    let executable = command;
    if (command !== cli) {
      if (command !== 'node' || args[0] !== cli || !/\.(?:js|mjs|tsx|ts|jsx)$/u.test(cli)) {
        throw new HostError('isolation_launch_invalid');
      }
      executable = node;
    }
    return spawn('/usr/bin/sandbox-exec', [
      '-p', profile, executable, ...args,
    ], options);
  }
  return spawn(command, args, options);
}

function isolationArtifact(raw) {
  let expected;
  try { expected = JSON.parse(raw); } catch { throw new HostError('isolation_launch_invalid'); }
  if (!expected || typeof expected.path !== 'string' || !expected.path.startsWith('/')
    || realpathSync(expected.path) !== expected.path) throw new HostError('isolation_launch_invalid');
  const actual = statSync(expected.path, { bigint: true });
  if (!actual.isFile() || actual.dev.toString() !== expected.device
    || actual.ino.toString() !== expected.inode || actual.size.toString() !== expected.size
    || actual.mtimeNs.toString() !== expected.mtimeNs) throw new HostError('isolation_artifact_changed');
  return expected.path;
}

// Children stay in the process group or Job Object owned by the Swift transport.
export class ClaudeProcesses {
  constructor() { this.children = new Set(); }

  spawn(options) {
    const child = spawnClaude(options.command, options.args, {
      cwd: options.cwd, env: options.env, signal: options.signal,
      stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
    });
    const entry = { child, exited: null };
    entry.exited = new Promise(resolve => {
      child.once('exit', resolve);
      child.once('error', () => { if (!child.pid) resolve(); });
    });
    child.stderr.resume();
    this.children.add(entry);
    return child;
  }

  async close() {
    for (const entry of this.children) {
      if (!await wait(entry.exited, 8000)) {
        entry.child.kill('SIGKILL');
        if (!await wait(entry.exited, 3000)) throw new HostError('process_exit_unconfirmed');
      }
      this.children.delete(entry);
    }
  }
}

async function wait(promise, milliseconds) {
  let timer;
  try {
    return await Promise.race([promise.then(() => true),
      new Promise(resolve => { timer = setTimeout(() => resolve(false), milliseconds); })]);
  } finally { clearTimeout(timer); }
}
