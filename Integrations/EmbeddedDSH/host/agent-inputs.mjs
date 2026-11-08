import { createHash, randomUUID } from 'node:crypto';

const terminal = new Set(['completed', 'failed', 'interrupted', 'cancelled']);

export class AgentInputs {
  constructor(bridge) {
    this.bridge = bridge;
    this.sending = new Map();
  }
  isSending(childID, requestID) { return this.sending.has(`${childID}:${requestID}`); }
  async persistNew(round) {
    this.bridge.bindings.push(round);
    try { await this.bridge.persist(); }
    catch (error) {
      const index = this.bridge.bindings.indexOf(round);
      if (index !== -1) this.bridge.bindings.splice(index, 1);
      throw error;
    }
  }
  async send(childID, prompt, requestID = randomUUID(), rootSessionID, options = {}) {
    const { bridge } = this;
    const binding = [...bridge.bindings].reverse().find(item => item.childID === childID && item.inputKind !== 'steer');
    if (!binding) throw new Error('Bridge subagent not found');
    if (binding.rootSessionID !== rootSessionID) throw new Error('Subagent belongs to another session');
    const { attachmentPaths = [], delivery = 'auto', repairConflict = false, expectedTaskID, expectedRunID } = options;
    if (!['auto', 'queue', 'steer'].includes(delivery)) throw new Error('Unsupported subagent delivery mode');
    if (!Array.isArray(attachmentPaths) || !attachmentPaths.every(path => typeof path === 'string') || typeof repairConflict !== 'boolean') {
      throw new Error('Invalid subagent attachment or repair options');
    }
    if (repairConflict && delivery === 'steer') throw new Error('Workspace repair requires a queued continuation');
    const promptHash = createHash('sha256').update(JSON.stringify({ prompt, attachmentPaths, delivery, repairConflict,
      expectedTaskID, expectedRunID })).digest('hex');
    const legacyHash = createHash('sha256').update(prompt).digest('hex');
    const key = `${childID}:${requestID}`;
    const inFlight = this.sending.get(key);
    if (inFlight) {
      if (inFlight.promptHash !== promptHash) throw new Error('Request ID is already bound to another instruction');
      return inFlight.result;
    }
    const existing = bridge.bindings.find(item => item.childID === childID && item.requestID === requestID);
    if (existing) {
      if (existing.promptHash !== promptHash && !(attachmentPaths.length === 0 && existing.promptHash === legacyHash)) {
        throw new Error('Request ID is already bound to another instruction');
      }
      if (['unknown', 'dispatching', 'delivery_unknown'].includes(existing.admission)) return { accepted: true, childID,
        state: 'checking', ...(existing.admission === 'delivery_unknown' ? { reason: 'delivery_unknown' } : {}) };
      if (existing.taskID) return { accepted: true, childID, taskID: existing.taskID, delivery: existing.inputKind === 'steer' ? 'steer' : 'queue' };
      if (existing.admission === 'cancelled') return { accepted: false, childID,
        state: existing.state === 'failed' ? 'failed' : 'cancelled',
        ...(existing.failureReason ? { error: existing.failureReason } : {}) };
      return { accepted: true, childID, queued: true, delivery: 'queue' };
    }
    bridge.assertCurrent(childID, expectedTaskID, expectedRunID);
    const result = this.sendNew(binding, prompt, requestID, promptHash,
      { attachmentPaths, delivery, repairConflict, expectedTaskID, expectedRunID });
    this.sending.set(key, { promptHash, result });
    try { return await result; }
    finally { this.sending.delete(key); }
  }
  receipt(rootSessionID, childID, requestID) {
    if (this.sending.has(`${childID}:${requestID}`)) return { state: 'unknown' };
    const binding = this.bridge.bindings.find(row => row.rootSessionID === rootSessionID &&
      row.childID === childID && row.requestID === requestID);
    if (!binding) return { state: 'notFound' };
    if (binding.admission === 'cancelled') return binding.state === 'failed'
      ? { state: 'failed', error: binding.failureReason } : { state: 'cancelled' };
    if (binding.admission === 'waiting') return { state: 'queued' };
    if (['unknown', 'dispatching', 'delivery_unknown'].includes(binding.admission)) return { state: 'unknown',
      ...(binding.admission === 'delivery_unknown' ? { reason: 'delivery_unknown', ...(binding.taskID ? { taskID: binding.taskID } : {}) } : {}) };
    return { state: 'accepted', ...(binding.taskID ? { taskID: binding.taskID } : {}) };
  }
  async sendNew(binding, prompt, requestID, promptHash, { attachmentPaths, delivery, repairConflict, expectedTaskID, expectedRunID }) {
    const { bridge } = this;
    const { rootSessionID, childID, installationID, parentSessionID, initialRequestID, label, createdAt } = binding;
    const previous = repairConflict ? [...bridge.bindings].reverse().find(row =>
      row.childID === childID && row.taskID && row.inputKind !== 'steer') ?? binding : binding;
    const round = { rootSessionID, childID, installationID, parentSessionID, initialRequestID, label, createdAt,
      requestID, promptHash, state: 'created', admission: 'waiting', deliveryRequired: true, previousRequestID: previous.requestID,
      ...(expectedTaskID && previous.taskID === expectedTaskID ? { previousTaskID: expectedTaskID } : {}),
      ...(expectedRunID && previous.runID === expectedRunID ? { previousRunID: expectedRunID } : {}),
      ...(terminal.has(previous.state) ? { requestedAfterTerminal: true } : {}),
      ...(repairConflict ? { repairConflict: true } : {}),
      ...(attachmentPaths.length ? { attachmentPaths } : {}) };
    const active = bridge.starting.get(childID)?.binding ?? [...bridge.bindings].reverse().find(row =>
      row.childID === childID && row.inputKind !== 'steer' && row.admission === 'accepted' && !terminal.has(row.state));
    let snapshot;
    if (delivery === 'auto' && repairConflict) delivery = 'queue';
    if (delivery === 'auto') {
      if (active?.taskID && !terminal.has(active.state) && !attachmentPaths.length) {
        snapshot = await bridge.rpc.request('bridge/subagent', { operation: 'get', ...active });
        if (snapshot.taskID !== active.taskID) throw new Error('Bridge returned a snapshot for another subagent task');
        bridge.rememberSnapshot(active, snapshot);
      }
      delivery = snapshot?.capabilities?.canSteer === true ? 'steer' : 'queue';
    }
    if (delivery === 'steer') {
      if (!active?.taskID || terminal.has(active.state)) throw new Error('The subagent is not running');
      if (attachmentPaths.length) throw new Error('Running subagents cannot receive attachments; queue a continuation instead');
      snapshot ??= await bridge.rpc.request('bridge/subagent', { operation: 'get', ...active });
      if (snapshot.taskID !== active.taskID || snapshot.capabilities?.canSteer !== true) {
        throw new Error('This subagent cannot receive a running instruction; queue a continuation instead');
      }
      bridge.assertCurrent(childID, expectedTaskID, expectedRunID);
      bridge.rememberSnapshot(active, snapshot);
      Object.assign(round, { inputKind: 'steer', admission: 'dispatching' });
      await this.persistNew(round);
      let dispatched = false;
      try {
        bridge.assertCurrent(childID, expectedTaskID, expectedRunID);
        dispatched = true;
        const receipt = await bridge.rpc.request('bridge/subagent', { operation: 'send', ...active, requestID, prompt });
        if (receipt.taskID !== active.taskID) throw new Error('Bridge returned a receipt for another subagent task');
        Object.assign(round, { taskID: receipt.taskID, state: receipt.state, admission: 'attached' });
        await bridge.persist();
        return { accepted: true, childID, taskID: round.taskID, delivery: 'steer' };
      } catch (error) {
        if (dispatched) round.admission = 'unknown';
        else Object.assign(round, { admission: 'cancelled', state: 'failed', failureReason: error.message });
        await bridge.persist();
        throw error;
      }
    }
    const current = active ?? [...bridge.bindings].reverse().find(row => row.childID === childID && row.taskID && row.inputKind !== 'steer');
    const waitingForMerge = current?.workspaceMode === 'isolated' &&
      [undefined, 'pending', 'conflict', 'validation_required', 'recovery_required'].includes(current.workspaceStatus);
    if (current?.capabilities?.supportsContinue === false ||
        (terminal.has(current?.state) && current?.capabilities?.canContinue === false && !waitingForMerge)) {
      throw new Error('This subagent cannot continue from its current state');
    }
    bridge.assertCurrent(childID, expectedTaskID, expectedRunID);
    Object.assign(round, { pendingOperation: 'send', pendingPrompt: prompt });
    await this.persistNew(round);
    bridge.resumeNext(childID);
    return { accepted: true, childID, queued: true, delivery: 'queue' };
  }
}
