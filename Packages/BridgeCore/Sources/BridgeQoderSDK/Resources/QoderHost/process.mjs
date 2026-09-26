import { spawn } from 'node:child_process';
import path from 'node:path';
import { HostError } from './validation.mjs';

export class SDKProcessOwner {
  constructor() { this.children = new Set(); }

  spawn(options) {
    const child = spawn(options.command, options.args, {
      cwd: options.cwd, env: options.env, signal: options.signal,
      stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
      detached: process.platform !== 'win32',
    });
    const entry = { child, exited: null, terminationError: null };
    const originalKill = child.kill.bind(child);
    child.kill = signal => {
      if (!child.pid) return originalKill(signal);
      if (process.platform === 'win32') {
        void terminateTree(child).catch(error => { entry.terminationError = error; });
        return true;
      }
      try { process.kill(-child.pid, signal); return true; }
      catch (error) { if (error.code === 'ESRCH') return false; throw error; }
    };
    entry.exited = new Promise(resolve => {
      child.once('exit', () => resolve());
      child.once('error', () => { if (!child.pid) resolve(); });
    });
    child.stderr.resume();
    this.children.add(entry);
    return child;
  }

  async close() {
    await Promise.all([...this.children].map(async entry => {
      const stopped = await waitForExit(entry.exited, 8000);
      if (!stopped) {
        await terminateTree(entry.child);
        if (!await waitForExit(entry.exited, 3000)) throw new HostError('process_exit_unconfirmed');
      }
      if (entry.terminationError) throw new HostError('process_tree_exit_unconfirmed');
      this.children.delete(entry);
    }));
  }
}

async function terminateTree(child) {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform !== 'win32') { child.kill('SIGKILL'); return; }
  const systemRoot = process.env.SystemRoot ?? process.env.SYSTEMROOT;
  if (!systemRoot) throw new HostError('windows_system_root_missing');
  await new Promise((resolve, reject) => {
    const killer = spawn(path.join(systemRoot, 'System32', 'taskkill.exe'),
      ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true });
    killer.once('error', reject);
    killer.once('exit', code => {
      if (code === 0 || child.exitCode !== null || child.signalCode !== null) resolve();
      else reject(new HostError('process_tree_exit_unconfirmed'));
    });
  });
}

async function waitForExit(exited, timeout) {
  let timer;
  try {
    return await Promise.race([exited.then(() => true),
      new Promise(resolve => { timer = setTimeout(() => resolve(false), timeout); })]);
  } finally { clearTimeout(timer); }
}
