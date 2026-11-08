import { setTimeout as delay } from 'node:timers/promises';

const failed = new Set(['failed', 'interrupted', 'cancelled']);

export class AgentDependencyError extends Error {}

export function handoffPrompt({ prompt, context, scope }) {
  return [prompt, context && `Context:\n${context}`, scope && `Scope:\n${scope}`].filter(Boolean).join('\n\n');
}

export function dependenciesFor(bindings, rootSessionID, childIDs = []) {
  return [...new Set(childIDs)].map(childID => {
    const binding = [...bindings].reverse().find(row => row.rootSessionID === rootSessionID &&
      row.childID === childID && row.admission !== 'attached');
    if (!binding) throw new Error(`Dependency ${childID} is not a connected subagent in this session`);
    return { childID, requestID: binding.requestID };
  });
}

export async function waitForDependencies(binding, bindings, rpc, signal, changed) {
  if (!binding.dependencies?.length) return;
  for (;;) {
    signal?.throwIfAborted();
    const pending = [];
    for (const dependency of binding.dependencies) {
      const target = bindings.find(row => row.rootSessionID === binding.rootSessionID &&
        row.childID === dependency.childID && row.requestID === dependency.requestID);
      if (!target) throw new Error(`Dependency ${dependency.childID} is unavailable`);
      if (failed.has(target.state) || target.admission === 'cancelled') {
        throw new AgentDependencyError(`Dependency ${dependency.childID} ended with ${target.state}; delegate the dependent task again after recovery`);
      }
      if (!target.taskID) {
        pending.push({ childID: dependency.childID, state: target.state ?? 'waiting' });
        continue;
      }
      const snapshot = await rpc.request('bridge/subagent', { operation: 'get', rootSessionID: binding.rootSessionID,
        childID: dependency.childID, requestID: dependency.requestID, taskID: target.taskID });
      if (snapshot.taskID !== target.taskID) throw new Error('Dependency task changed while checking its result');
      if (failed.has(snapshot.state)) throw new AgentDependencyError(`Dependency ${dependency.childID} ended with ${snapshot.state}; delegate the dependent task again after recovery`);
      if (snapshot.workspaceStatus === 'failed' || snapshot.workspaceStatus === 'retained') {
        throw new AgentDependencyError(`Dependency ${dependency.childID} has workspace status ${snapshot.workspaceStatus}; resolve it before delegating again`);
      }
      if (snapshot.state !== 'completed' || (snapshot.workspaceMode === 'isolated' && snapshot.workspaceStatus !== 'merged')) {
        pending.push({ childID: dependency.childID, state: snapshot.state,
          ...(snapshot.workspaceStatus ? { workspaceStatus: snapshot.workspaceStatus } : {}) });
      }
    }
    const state = JSON.stringify(pending);
    if (binding.dependencyState !== state) {
      binding.dependencyState = state;
      await changed(pending);
    }
    if (!pending.length) return;
    await delay(1000, undefined, { signal });
  }
}

export async function waitForPreviousRound(binding, bindings, rpc, signal, changed) {
  if (binding.pendingOperation !== 'send') return;
  const index = bindings.indexOf(binding);
  const previous = binding.previousRequestID
    ? bindings.find(row => row.rootSessionID === binding.rootSessionID && row.childID === binding.childID && row.requestID === binding.previousRequestID)
    : bindings.slice(0, index).reverse().find(row => row.childID === binding.childID && row.inputKind !== 'steer');
  if (!previous) throw new AgentDependencyError('The previous subagent request is unavailable');
  for (;;) {
    signal?.throwIfAborted();
    if ((failed.has(previous.state) || previous.admission === 'cancelled') &&
        (!binding.requestedAfterTerminal || !previous.taskID)) {
      throw new AgentDependencyError(`The previous subagent request ended with ${previous.state}; submit a new instruction after recovery`);
    }
    if (previous.taskID) {
      if (binding.previousTaskID && binding.previousTaskID !== previous.taskID) {
        throw new AgentDependencyError('The previous subagent task changed before the queued instruction was dispatched');
      }
      const snapshot = await rpc.request('bridge/subagent', { operation: 'get', rootSessionID: binding.rootSessionID,
        childID: binding.childID, requestID: previous.requestID, taskID: previous.taskID });
      if (snapshot.taskID !== previous.taskID) throw new Error('The previous subagent task changed while checking its result');
      if (failed.has(snapshot.state)) {
        if (binding.requestedAfterTerminal && snapshot.capabilities?.canContinue === true &&
            (snapshot.workspaceMode !== 'isolated' || snapshot.workspaceStatus === 'retained')) return true;
        throw new AgentDependencyError(`The previous subagent request ended with ${snapshot.state}; submit a new instruction after recovery`);
      }
      if (snapshot.state === 'completed') {
        if (snapshot.workspaceMode !== 'isolated' || snapshot.workspaceStatus === 'merged') return true;
        if (snapshot.workspaceStatus === 'conflict' && binding.repairConflict === true &&
            (snapshot.canRepairWithAgent === true || snapshot.capabilities?.canRepairWithAgent === true)) return true;
        if (['failed', 'retained'].includes(snapshot.workspaceStatus)) {
          throw new AgentDependencyError(`The previous subagent workspace is ${snapshot.workspaceStatus}; resolve it before continuing`);
        }
        if (await changed(snapshot.workspaceStatus ?? 'pending')) return false;
      }
    }
    await delay(1000, undefined, { signal });
  }
}
