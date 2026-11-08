import { randomBytes } from 'node:crypto';
import { lstatSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync, fsyncSync, closeSync } from 'node:fs';
import { join } from 'node:path';
import { WorkspaceProcessInspector } from './workspace-process-inspection.mjs';

const randomID = () => randomBytes(16).toString('hex');
const safeID = value => typeof value === 'string' && /^[0-9a-f]{32}$/.test(value);
const validProcess = value => value && Number.isSafeInteger(value.pid) && value.pid > 1 &&
  typeof value.started === 'string' && value.started.length <= 64 && /^[0-9:]+$/.test(value.started);
const validRange = range => validProcess(range) && ['group', 'terminal', 'systemd', 'windows-job', 'windows-terminal', 'unknown'].includes(range.kind) &&
  Array.isArray(range.members) && range.members.length <= 4096 && range.members.every(validProcess) &&
  (range.kind !== 'terminal' || Number.isSafeInteger(range.session) && range.session > 1) &&
  (range.kind !== 'systemd' || typeof range.unit === 'string' && /^dsh-subprocess-[0-9]+-[a-f0-9]+\.scope$/.test(range.unit));

export class WorkspaceProcessScopes {
  constructor(home) {
    this.directory = join(home, 'workspace-write-scopes');
    try { this.inspector = new WorkspaceProcessInspector(); } catch { this.inspector = undefined; }
  }

  async start() {
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const stat = lstatSync(this.directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Invalid workspace process storage');
    try {
      await this.inspector?.start();
      this.host = this.inspector?.identity(process.pid);
    } catch { this.inspector = undefined; }
  }

  path(id) {
    if (!safeID(id)) throw new Error('Invalid workspace process identity');
    return join(this.directory, `${id}.json`);
  }

  create(rootID, ownerID) {
    const record = { version: 1, id: randomID(), rootID, ownerID, host: this.host,
      spawning: 0, incomplete: !this.host, ranges: [] };
    this.write(record);
    return record;
  }

  read(id, rootID, ownerID) {
    const path = this.path(id);
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 * 1024) throw new Error('Invalid workspace process record');
    const record = JSON.parse(readFileSync(path, 'utf8'));
    if (record.version !== 1 || record.id !== id || record.rootID !== rootID ||
        !Array.isArray(record.ranges) || record.ranges.length > 128 || !record.ranges.every(validRange) ||
        (record.host !== undefined && !validProcess(record.host)) ||
        !Number.isSafeInteger(record.spawning) || record.spawning < 0 || record.spawning > 128) {
      throw new Error('Invalid workspace process record');
    }
    return record;
  }

  write(record) {
    const path = this.path(record.id);
    const temporary = `${path}.${randomID()}.tmp`;
    const data = Buffer.from(`${JSON.stringify(record)}\n`);
    if (data.length > 1024 * 1024) throw new Error('Workspace process record exceeds its size limit');
    const fd = openSync(temporary, 'wx', 0o600);
    try { writeFileSync(fd, data); fsyncSync(fd); } finally { closeSync(fd); }
    try { renameSync(temporary, path); } catch (error) { try { unlinkSync(temporary); } catch {} throw error; }
  }

  begin(record) { record.spawning++; this.write(record); }
  finish(record) {
    record.spawning--;
    try { this.write(record); } catch (error) { record.spawning++; throw error; }
  }
  incomplete(record) { record.incomplete = true; this.write(record); }

  attach(record, pid, kind, unit) {
    if (record.ranges.length >= 128) { this.incomplete(record); return undefined; }
    const identity = this.inspector?.identity(pid);
    if (!identity) { this.incomplete(record); return undefined; }
    if (['group', 'systemd'].includes(kind) && this.inspector.group(pid) !== pid) {
      this.incomplete(record);
      return undefined;
    }
    const range = { ...identity, kind, ...(unit ? { unit } : {}), members: [] };
    if (kind === 'terminal') {
      range.session = this.inspector.session(pid);
      if (range.session !== pid) { this.incomplete(record); return undefined; }
    }
    record.ranges.push(range);
    this.write(record);
    return range;
  }

  refresh(record, snapshot) {
    if (!record.ranges.length) return;
    snapshot ??= this.inspector.table();
    let changed = false;
    let incomplete = record.incomplete;
    const states = record.ranges.map(original => {
      const range = { ...original, members: [...original.members] };
      return { range, state: this.inspector.inspect(range, snapshot) };
    });
    const live = states.filter(({ range, state }) => {
      const exited = state.status === 'exited' && range.kind !== 'unknown' &&
        (range.kind !== 'systemd' || range.established);
      if (exited) changed = true;
      return !exited;
    });
    let memberCount = live.reduce((count, { range }) => count + range.members.length, 0);
    for (const { range, state } of live) {
      if (state.established && !range.established) { range.established = true; changed = true; }
      const members = range.kind === 'systemd' && state.status === 'unknown'
        ? this.inspector.members(range, snapshot) : state.processes;
      for (const member of members) {
        if (range.members.some(known => known.pid === member.pid && known.started === member.started)) continue;
        if (memberCount >= 4096) { incomplete = true; changed = true; break; }
        range.members.push(member);
        memberCount++;
        changed = true;
      }
    }
    if (changed) {
      const ranges = live.map(({ range }) => range);
      this.write({ ...record, ranges, incomplete });
      record.ranges = ranges;
      record.incomplete = incomplete;
    }
  }

  gate(record) { return join(this.directory, `${record.id}.${randomID()}.ready`); }
  allow(gate) { const fd = openSync(gate, 'wx', 0o600); try { fsyncSync(fd); } finally { closeSync(fd); } }

  inspect(record, snapshotForInspection = () => this.inspector.table()) {
    if (!this.inspector || !record.host) return { status: 'unknown', processes: [], canTerminate: false };
    if (record.host.boot && !this.inspector.boot) return { status: 'unknown', processes: [], canTerminate: false };
    if (record.host.boot && record.host.boot !== this.inspector.boot) return { status: 'exited', processes: [], canTerminate: false };
    if (this.inspector.same(record.host)) return { status: 'unknown', hostAlive: true, processes: [], canTerminate: false };
    let changed = false;
    let snapshot;
    try { snapshot = record.ranges.length ? snapshotForInspection() : undefined; }
    catch { return { status: 'unknown', processes: [], canTerminate: false }; }
    const ranges = record.ranges.map(range => {
      try {
        const state = this.inspector.inspect(range, snapshot);
        if (state.established && !range.established) { range.established = true; changed = true; }
        return state;
      }
      catch { return { status: 'unknown', processes: [], canTerminate: false }; }
    });
    if (changed) this.write(record);
    const processes = ranges.flatMap(range => range.processes.map(member => ({ pid: member.pid, label: '后台进程' })));
    if (record.spawning || record.incomplete || ranges.some(range => range.status === 'unknown')) {
      return { status: 'unknown', processes, canTerminate: ranges.some(range => range.canTerminate) };
    }
    if (ranges.some(range => range.status === 'running')) {
      return { status: 'running', processes, canTerminate: ranges.every(range => range.status === 'exited' || range.canTerminate) };
    }
    return { status: 'exited', processes: [], canTerminate: false };
  }

  async terminate(record) {
    const state = this.inspect(record);
    if (!state.canTerminate) throw new Error('The process identity cannot be confirmed');
    for (const range of record.ranges) {
      if (this.inspector.inspect(range).canTerminate) await this.inspector.terminate(range);
    }
  }

  remove(id) {
    try { unlinkSync(this.path(id)); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    for (const name of readdirSync(this.directory)) {
      if (!name.startsWith(`${id}.`) || !name.endsWith('.ready')) continue;
      try { unlinkSync(join(this.directory, name)); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
  }
}
