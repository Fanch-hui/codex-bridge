import { createHash } from 'node:crypto';
import { createUserMessage, freezeMessage } from '@deepseek-ai/dsh-llm';
import { hasNotice, recordNotice } from './agent-notices.mjs';
import { workspaceNotice } from './workspace-notice.mjs';
import { SkippedResults } from './agent-results.mjs';

const deliveryID = result => `bridge-${createHash('sha256').update(JSON.stringify([result.rootSessionID, result.childID, result.requestID, result.taskID ?? null])).digest('hex')}`;
const senderMarker = childID => `"senderSessionId":"${childID}"`;
const key = (rootID, childID, requestID) => JSON.stringify([rootID, childID, requestID]);

/** Adds the child to the parent's subagent catalog once, so the page and the model list it. */
export function recordChild(parent, { childID, createdAt, label }) {
  if (parent.session.snapshotEvents().some(event => event.type === 'subagent/catalog' && event.data.childId === childID)) return;
  parent.session.append('subagent/catalog', { version: 2, childId: childID,
    childCreatedAt: createdAt ?? Date.now(), mode: 'external', ...(label ? { label } : {}) });
}

/** What an activation settles with once the Service reports its child's first result. */
export function activationResult(result) {
  const output = [result.output, workspaceNotice(result)].filter(Boolean).map(text => ({ type: 'text', text }));
  return { output,
    stopReason: result.state === 'completed' ? 'completed' : result.state === 'interrupted' ? 'aborted' : 'error',
    ...(result.error ? { diagnostic: String(result.error).slice(0, 4096) } : {}) };
}

/**
 * Hands the Service's finished subagent results to their parent sessions. The Service decides what is
 * due (`round.pending`) and records what was handed over (`round.ack`); this only writes the notice into
 * the parent and waits until it is persisted. A result whose child was started by a live activation is
 * delivered by the engine itself: the activation's `result` settles with it and `delivered` runs after.
 *
 * The Service announces new results (`kick`); the interval only covers a lost announcement and runs for
 * roots that still have unfinished work.
 */
export class ResultDelivery {
  constructor({ ctx, sessions, round, interval = 5000 }) {
    this.ctx = ctx;
    this.sessions = sessions;
    this.round = round;
    this.watched = new Set();
    this.cycles = new Map();
    this.waiters = new Map();
    this.skipped = new SkippedResults();
    this.timer = setInterval(() => { for (const rootID of this.watched) this.kick(rootID); }, interval);
    this.timer.unref();
  }
  dispose() { clearInterval(this.timer); }
  /** Registers the activation waiting for the first result of a child. */
  waitFor(rootID, childID, requestID) {
    const waiter = { rootID, childID, requestID, settled: false };
    waiter.promise = new Promise((resolve, reject) => {
      waiter.resolve = result => { waiter.result ??= result; waiter.settled = true; resolve(result); };
      waiter.reject = error => { waiter.settled = true; reject(error); };
    });
    waiter.promise.catch(() => {});
    this.waiters.set(key(rootID, childID, requestID), waiter);
    return waiter;
  }
  waiterOf(rootID, childID) {
    return [...this.waiters.values()].find(waiter => waiter.rootID === rootID && waiter.childID === childID);
  }
  forget(waiter) {
    if (this.waiters.get(key(waiter.rootID, waiter.childID, waiter.requestID)) === waiter) {
      this.waiters.delete(key(waiter.rootID, waiter.childID, waiter.requestID));
    }
  }
  awaiting(rootID) {
    return [...this.waiters.values()].filter(waiter => waiter.rootID === rootID)
      .map(({ childID, requestID }) => ({ childID, requestID }));
  }
  /** Checks the root now; calls while a check runs share one follow-up. */
  kick(rootID) {
    this.watched.add(rootID);
    const running = this.cycles.get(rootID);
    if (running) { running.again = true; return running.done; }
    const cycle = { again: false };
    cycle.done = (async () => {
      do {
        cycle.again = false;
        try { await this.cycle(rootID); }
        catch (error) { process.stderr.write(`DSH subagent delivery failed: ${error.message}\n`); }
      } while (cycle.again);
      this.cycles.delete(rootID);
    })();
    this.cycles.set(rootID, cycle);
    return cycle.done;
  }
  async cycle(rootID) {
    const awaiting = this.awaiting(rootID);
    const batch = await this.round('pending', rootID, awaiting.length ? { awaiting } : {});
    this.skipped.report(rootID, batch.skipped);
    for (const result of batch.results) {
      const waiter = this.waiters.get(key(rootID, result.childID, result.requestID));
      if (waiter) { waiter.resolve(result); continue; }
      try { await this.deliver(rootID, result); }
      catch (error) { process.stderr.write(`DSH subagent delivery failed (child ${result.childID}): ${error.message}\n`); }
    }
    if (batch.stopped || (!batch.hasUnfinished && !this.awaiting(rootID).length)) this.watched.delete(rootID);
  }
  /** Writes the notice of a result into its parent session and acknowledges it. Returns false while the root is stopped. */
  async deliver(rootID, result) {
    if (this.sessions.stopGate.isStopped(rootID)) return false;
    const found = await this.ctx.sessionController.resolveAgent(result.parentSessionID);
    if (found.error) throw found.error;
    const parent = found.agent;
    if (result.origin === 'user') return this.deliverQuietly(rootID, parent, result);
    const rootAgent = rootID === result.parentSessionID ? parent : await this.sessions.agent(rootID);
    let group, generation;
    try { ({ group, generation } = await this.sessions.begin(rootID, rootAgent)); }
    catch (error) { if (this.sessions.stopGate.isStopped(rootID)) return false; throw error; }
    try {
      if (this.sessions.stopGate.isStopped(rootID)) return false;
      await this.write(parent, { ...result, rootSessionID: rootID });
      if (!await this.ctx.sessions.flush(parent.session)) throw new Error('Parent session could not be persisted');
      if (this.sessions.stopGate.isStopped(rootID)) return false;
      await this.acknowledge(rootID, result);
      return true;
    } finally { setImmediate(() => void this.sessions.settle(rootID, rootAgent, group, generation)); }
  }
  /** A result of work the user handed over directly is only written down; no model runs for it, so no execution is opened. */
  async deliverQuietly(rootID, parent, result) {
    this.write(parent, { ...result, rootSessionID: rootID });
    if (!await this.ctx.sessions.flush(parent.session)) throw new Error('Parent session could not be persisted');
    if (this.sessions.stopGate.isStopped(rootID)) return false;
    await this.acknowledge(rootID, result);
    return true;
  }
  write(parent, result) {
    const id = deliveryID(result);
    const events = parent.session.snapshotEvents();
    // The notice of a direct hand-over names the child too, so it does not prove the engine recorded the result.
    const nativeFirst = result.kind === 'start' && result.origin !== 'user' &&
      events.some(event => JSON.stringify(event.data).includes(senderMarker(result.childID)));
    recordChild(parent, result);
    if (hasNotice(parent.session, id) || nativeFirst) return;
    const summary = `Bridge subagent ${result.childID}, request ${result.requestID}, finished (${result.state}).`;
    const detail = [result.output ?? result.error ?? '', workspaceNotice(result)].filter(Boolean).join('\n');
    const message = createUserMessage({ content: [{ type: 'text', text: `${summary}\n${detail}` }],
      source: { kind: 'subagent-settled', form: 'notice', summary, senderSessionId: result.childID } });
    const notice = freezeMessage({ ...message, id });
    if (result.origin === 'user') recordNotice(parent.session, notice); else parent.steer(notice);
  }
  acknowledge(rootID, { childID, requestID, taskID }) {
    return this.round('ack', rootID, { childID, requestID, ...(taskID ? { taskID } : {}) });
  }
  /**
   * After an activation settled with the first result of its child: waits until the engine recorded it
   * in the parent and persisted it, then acknowledges it.
   */
  async delivered(parent, rootID, result) {
    if (this.sessions.stopGate.isStopped(rootID)) return;
    const recorded = parent.session.snapshotEvents().some(event => JSON.stringify(event.data).includes(senderMarker(result.childID)));
    if (!recorded || !await this.ctx.sessions.flush(parent.session)) throw new Error('Subagent result is not yet persisted');
    if (this.sessions.stopGate.isStopped(rootID)) return;
    await this.acknowledge(rootID, result);
  }
}
