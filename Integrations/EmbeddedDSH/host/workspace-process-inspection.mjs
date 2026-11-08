import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

export class WorkspaceProcessInspector {
  constructor() {
    this.platform = process.platform;
    if (this.platform === 'linux') this.boot = readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
    if (this.platform === 'darwin') {
      const boot = /sec = (\d+), usec = (\d+)/.exec(execFileSync('/usr/sbin/sysctl', ['-n', 'kern.boottime'],
        { encoding: 'utf8', maxBuffer: 4096 }));
      if (!boot) throw new Error('System boot identity is unavailable');
      this.boot = `${boot[1]}:${boot[2]}`;
      const resolveFromProvider = createRequire(require.resolve('@deepseek-ai/dsh-subprocess-local/package.json'));
      const koffi = resolveFromProvider('koffi');
      const proc = koffi.load('/usr/lib/libproc.dylib');
      const libc = koffi.load('/usr/lib/libSystem.B.dylib');
      this.procInfo = proc.func('int proc_pidinfo(int, int, uint64_t, void *, int)');
      this.getsid = libc.func('int getsid(int)');
      this.getpgid = libc.func('int getpgid(int)');
    }
  }

  async start() {
    if (this.platform !== 'win32') return;
    const provider = dirname(require.resolve('@deepseek-ai/dsh-subprocess-local/package.json'));
    const chunks = readdirSync(join(provider, 'lib')).filter(name => /^runner-launch-.*\.js$/.test(name));
    if (chunks.length !== 1) throw new Error('Windows process inspection is unavailable');
    const factory = (await import(pathToFileURL(join(provider, 'lib', chunks[0])).href)).D;
    if (typeof factory !== 'function') throw new Error('Windows process inspection is unavailable');
    this.windows = factory();
  }

  identity(pid, snapshot) {
    if (!Number.isSafeInteger(pid) || pid < 2) return undefined;
    if (this.platform === 'darwin') {
      const data = Buffer.alloc(136);
      if (this.procInfo(pid, 3, 0, data, data.length) !== data.length || data.readUInt32LE(12) !== pid) return undefined;
      return { pid, started: `${data.readBigUInt64LE(120)}:${data.readBigUInt64LE(128)}`, boot: this.boot };
    }
    if (this.platform === 'linux') {
      try {
        const value = readFileSync(`/proc/${pid}/stat`, 'utf8');
        const fields = value.slice(value.lastIndexOf(')') + 2).split(' ');
        if (fields.length < 20) return undefined;
        return { pid, started: fields[19], boot: this.boot };
      } catch { return undefined; }
    }
    return (snapshot ?? this.windows?.snapshot())?.tree(pid).find(row => row.pid === pid);
  }

  same(identity, snapshot) {
    const current = this.identity(identity.pid, snapshot);
    return current?.started === identity.started && (!identity.boot || current.boot === identity.boot);
  }

  session(pid) {
    if (this.platform === 'darwin') { const result = this.getsid(pid); return result > 1 ? result : undefined; }
    if (this.platform === 'linux') {
      try {
        const value = readFileSync(`/proc/${pid}/stat`, 'utf8');
        const fields = value.slice(value.lastIndexOf(')') + 2).split(' ');
        const result = Number(fields[3]);
        return result > 1 ? result : undefined;
      } catch { return undefined; }
    }
    return undefined;
  }

  group(pid) {
    if (this.platform === 'darwin') { const result = this.getpgid(pid); return result > 1 ? result : undefined; }
    if (this.platform === 'linux') {
      try {
        const value = readFileSync(`/proc/${pid}/stat`, 'utf8');
        const result = Number(value.slice(value.lastIndexOf(')') + 2).split(' ')[2]);
        return result > 1 ? result : undefined;
      } catch { return undefined; }
    }
    return undefined;
  }

  table() {
    if (this.platform === 'win32') return this.windows.snapshot();
    const output = execFileSync('/bin/ps', ['-A', '-o', 'pid=,ppid=,pgid=,state='],
      { encoding: 'utf8', env: { LC_ALL: 'C', PATH: '/usr/bin:/bin' }, maxBuffer: 4 * 1024 * 1024 });
    return output.split('\n').filter(Boolean).map(line => {
      const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s*$/.exec(line);
      if (!match) throw new Error('Process table is incomplete');
      return { pid: Number(match[1]), parent: Number(match[2]), group: Number(match[3]), state: match[4] };
    }).filter(row => !row.state.startsWith('Z'));
  }

  members(range, snapshot) {
    if (this.platform === 'win32') {
      snapshot ??= this.windows.snapshot();
      const root = snapshot.tree(range.pid).find(row => row.pid === range.pid);
      if (root?.started !== range.started) return [];
      return snapshot.tree(range.pid).filter(row => snapshot.alive(row));
    }
    const rows = (snapshot ?? this.table()).filter(row => range.kind === 'terminal'
      ? this.session(row.pid) === range.session : row.group === range.pid);
    return rows.map(row => {
      const identity = this.identity(row.pid);
      if (!identity) throw new Error('The process range could not be inspected');
      return identity;
    });
  }

  inspect(range, snapshot) {
    if (range.boot && !this.boot) return { status: 'unknown', canTerminate: false, processes: [] };
    if (range.boot && range.boot !== this.boot) return { status: 'exited', canTerminate: false, processes: [] };
    if (range.kind === 'systemd') return this.inspectSystemd(range, snapshot);
    if (this.platform === 'win32') {
      if (this.same(range, snapshot)) return { status: 'running', canTerminate: true, processes: this.members(range, snapshot) };
      const survivors = (range.members ?? []).filter(member => this.same(member, snapshot));
      if (survivors.length) return { status: 'unknown', canTerminate: true, processes: survivors };
      return { status: 'unknown', canTerminate: false, processes: [] };
    }
    const members = this.members(range, snapshot);
    if (!members.length) return { status: 'exited', canTerminate: false, processes: [] };
    const currentLeader = members.find(member => member.pid === range.pid);
    if (currentLeader && currentLeader.started !== range.started) return { status: 'exited', canTerminate: false, processes: [] };
    const identified = currentLeader?.started === range.started || members.some(member =>
      (range.members ?? []).some(known => known.pid === member.pid && known.started === member.started));
    return { status: identified ? 'running' : 'unknown', canTerminate: Boolean(identified), processes: members };
  }

  inspectSystemd(range, snapshot) {
    try {
      const output = execFileSync('systemctl', ['--user', 'show', range.unit,
        '--property=LoadState', '--property=ActiveState', '--property=TasksCurrent'],
      { encoding: 'utf8', timeout: 3000, maxBuffer: 8192 });
      const values = Object.fromEntries(output.trim().split('\n').map(line => line.split('=')));
      if (values.LoadState === 'not-found') {
        if (!range.established) return { status: 'unknown', canTerminate: false, processes: [] };
        return { status: 'exited', canTerminate: false, processes: [] };
      }
      if (['inactive', 'failed'].includes(values.ActiveState)) {
        return { status: 'exited', canTerminate: false, processes: [] };
      }
      if (values.LoadState === 'loaded' && ['active', 'activating', 'reloading', 'deactivating'].includes(values.ActiveState)) {
        return { status: 'running', established: true, canTerminate: true, processes: this.members(range, snapshot) };
      }
    } catch {}
    return { status: 'unknown', canTerminate: false, processes: [] };
  }

  async terminate(range) {
    const current = this.inspect(range);
    if (current.status === 'exited') return;
    if (!current.canTerminate) throw new Error('The process identity cannot be confirmed');
    for (const signal of ['SIGTERM', 'SIGKILL']) {
      if (range.kind === 'systemd') {
        execFileSync('systemctl', ['--user', 'kill', '--kill-who=all', `--signal=${signal}`, range.unit],
          { stdio: 'ignore', timeout: 3000 });
      } else if (this.platform === 'win32') {
        for (const member of current.processes) this.windows.signalProcess(member, signal);
      } else if (range.kind === 'terminal') {
        const groups = new Set(this.table().filter(row => this.session(row.pid) === range.session).map(row => row.group));
        for (const group of groups) { try { process.kill(-group, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; } }
      } else {
        try { process.kill(-range.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      }
      for (let attempt = 0; attempt < 20; attempt++) {
        await delay(50);
        const state = this.inspect(range);
        if (state.status === 'exited') return;
        if (!state.canTerminate) {
          if (state.status === 'unknown') return;
          throw new Error('The process identity changed while stopping');
        }
      }
    }
    throw new Error('The process range has not stopped');
  }
}
