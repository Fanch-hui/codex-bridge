const finished = new Set(['completed', 'failed', 'interrupted', 'cancelled']);
const snapshotFields = ['providerID', 'workspaceReason', 'changedFiles', 'changedFilesOmitted', 'conflicts',
  'conflictsOmitted', 'failureReason', 'canRepairWithAgent', 'waitingForApproval'];

/** Whether a message can be queued for the child (the page offers "queue" next to "send"). */
function canQueue(child, capabilities) {
  if (!finished.has(child.state)) return capabilities.supportsContinue === true;
  const waitingForMerge = child.workspaceMode === 'isolated' &&
    [undefined, 'pending', 'conflict', 'validation_required', 'recovery_required'].includes(child.workspaceStatus);
  return capabilities.canContinue === true || (capabilities.supportsContinue === true && waitingForMerge);
}

/** The fields the subagent list shows for a connected child, from the Service's `round.list` entry. */
export function listingFor(child) {
  const snapshot = child.snapshot ?? {};
  const capabilities = snapshot.capabilities;
  return { installationID: child.installationID, ...(child.origin ? { origin: child.origin } : {}),
    ...(child.model ? { model: child.model } : {}),
    ...(child.taskID ? { taskID: child.taskID } : {}),
    status: child.state, workspaceMode: child.workspaceMode ?? 'shared',
    ...(child.phase === 'queued' ? { admission: 'waiting' } : {}),
    ...(child.waitingReason ? { waitingReason: child.waitingReason } : {}),
    ...(child.waitingFor?.length ? { waitingFor: child.waitingFor } : {}), queuedCount: child.queuedCount ?? 0,
    ...(snapshot.runID ? { runID: snapshot.runID } : {}),
    ...(capabilities ? { capabilities: { ...capabilities, canQueue: canQueue(child, capabilities) } } : {}),
    ...(child.workspaceStatus ? { workspaceStatus: child.workspaceStatus } : {}),
    ...Object.fromEntries(snapshotFields.filter(key => snapshot[key] !== undefined).map(key => [key, snapshot[key]])) };
}
