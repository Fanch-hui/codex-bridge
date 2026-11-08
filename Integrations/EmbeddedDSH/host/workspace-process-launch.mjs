import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const runner = fileURLToPath(new URL('./workspace-process-runner.mjs', import.meta.url));

export function trackWorkspaceSpawn(scopes, record, spawn) {
  scopes.begin(record);
  const original = childProcess.spawn;
  let captured = false;
  childProcess.spawn = function (program, args, options) {
    options ??= {};
    const detached = process.platform !== 'win32' && options.detached === true && Boolean(scopes.host);
    const unitArg = process.platform === 'linux' && basename(program) === 'systemd-run'
      ? args.find(value => /^--unit=dsh-subprocess-[0-9]+-[a-f0-9]+$/.test(value)) : undefined;
    const unit = unitArg ? `${unitArg.slice(7)}.scope` : undefined;
    const windowsJob = process.platform === 'win32' && options.env?.DSH_SUBPROCESS_RUNNER === 'windows';
    const kind = unit && detached ? 'systemd' : detached ? 'group' : windowsJob ? 'windows-job' : 'unknown';
    const gate = detached ? scopes.gate(record) : undefined;
    const descriptors = Array.isArray(options.stdio) ? options.stdio.flatMap((value, index) =>
      index >= 3 && value !== 'ignore' ? [index] : []) : [];
    const request = detached ? JSON.stringify({ argv: [program, ...args], gate, host: scopes.host, descriptors }) : undefined;
    const child = detached ? original.call(this, process.execPath, [runner],
      { ...options, env: { ...(options.env ?? process.env), CODEX_BRIDGE_PROCESS_LAUNCH: request } })
      : original.call(this, program, args, options);
    captured = true;
    try {
      const range = scopes.attach(record, child.pid, kind, unit);
      if (!range || kind === 'unknown') scopes.incomplete(record);
      if (gate) {
        if (!range) throw new Error('The workspace process identity could not be recorded');
        scopes.allow(gate);
      }
      child.once('exit', () => { if (record.active !== false) { try { scopes.refresh(record); } catch {} } });
    } catch (error) {
      child.kill('SIGKILL');
      throw error;
    }
    return child;
  };
  syncBuiltinESMExports();
  try {
    const handle = spawn();
    if (!captured) scopes.incomplete(record);
    scopes.finish(record);
    return handle;
  } catch (error) {
    if (captured) record.poisoned = true;
    else {
      try { scopes.finish(record); } catch { record.poisoned = true; }
    }
    throw error;
  } finally {
    childProcess.spawn = original;
    syncBuiltinESMExports();
  }
}

export async function trackWorkspaceTerminal(scopes, record, spawn) {
  scopes.begin(record);
  let terminal;
  try {
    terminal = await spawn();
    scopes.attach(record, terminal.pid, process.platform === 'win32' ? 'windows-terminal' : 'terminal');
    terminal.done.finally(() => { if (record.active !== false) { try { scopes.refresh(record); } catch {} } }).catch(() => {});
    scopes.finish(record);
    return terminal;
  } catch (error) {
    if (terminal) {
      try { await terminal.terminate(); } catch { record.poisoned = true; }
    }
    if (!record.poisoned) {
      try { scopes.finish(record); } catch { record.poisoned = true; }
    }
    throw error;
  }
}
