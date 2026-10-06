import { randomUUID } from 'node:crypto';
import { fault } from './errors.mjs';

export class UiChannel {
  constructor() { this.commands = new Map(); this.waiters = new Set(); this.clientSeenAt = 0; }
  async open(sessionID) {
    if (Date.now() - this.clientSeenAt > 15000) throw fault('desktop_ui_unavailable', 'DSH Desktop window is not connected');
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { this.commands.delete(id); reject(fault('desktop_navigation_unconfirmed', 'Desktop did not acknowledge session navigation')); }, 10000);
      this.commands.set(id, { command: { id, sessionID }, complete: result => {
        clearTimeout(timeout);
        this.commands.delete(id);
        if (result.ok) resolve({ accepted: true, sessionID });
        else reject(fault('desktop_navigation_failed', result.message ?? 'Desktop navigation failed'));
      } });
      for (const wake of this.waiters) wake();
    });
  }
  async poll(signal) {
    this.clientSeenAt = Date.now();
    if (!this.commands.size) await new Promise(resolve => {
      const done = () => { clearTimeout(timeout); this.waiters.delete(done); signal?.removeEventListener('abort', done); resolve(); };
      const timeout = setTimeout(done, 5000);
      this.waiters.add(done);
      signal?.addEventListener('abort', done, { once: true });
    });
    this.clientSeenAt = Date.now();
    return { commands: [...this.commands.values()].map(item => item.command) };
  }
  acknowledge(params) {
    const command = this.commands.get(params.id);
    if (!command) return { accepted: false };
    command.complete(params);
    return { accepted: true };
  }
  close() {
    for (const item of [...this.commands.values()]) item.complete({ ok: false, message: 'Connector is closing' });
    for (const wake of this.waiters) wake();
  }
}
