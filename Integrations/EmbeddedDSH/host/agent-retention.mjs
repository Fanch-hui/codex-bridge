// Conservative cleanup of finished subagent binding records.
//
// A binding is one delegation or continuation round. Rounds stay addressable by request ID for idempotent
// retries (`AgentInputs.send`, `receipt`) and by child ID for follow-ups, so only superseded rounds that have
// been finished and delivered for a long time are dropped. Anything uncertain is kept.

export const retentionMs = 7 * 24 * 60 * 60 * 1000;

const terminal = new Set(['completed', 'failed', 'interrupted', 'cancelled']);
const inFlight = new Set(['waiting', 'dispatching', 'unknown', 'delivery_unknown']);

/** Nothing is left to dispatch, wait for, release or deliver for this record. */
export function isFinished(row) {
  if (row.pendingOperation || typeof row.pendingPrompt === 'string' || row.reservationHeld) return false;
  if (inFlight.has(row.admission)) return false;
  // A steer is complete once Bridge attached it to the running task or it was rejected before dispatch.
  if (row.inputKind === 'steer') return row.admission === 'attached' || row.admission === 'cancelled';
  // A task keeps its record until the result was acknowledged, because Bridge keeps listing unacknowledged results.
  return terminal.has(row.state) && (!row.taskID || row.resultDelivered === true);
}

const last = (rows, predicate) => rows.findLast(predicate);

function protectedRows(rows) {
  const keep = new Set();
  const byChild = Map.groupBy(rows, row => row.childID);
  for (const childRows of byChild.values()) {
    // The latest records are what follow-up, stop, dependency, listing and change lookups resolve to.
    for (const row of [
      last(childRows, item => item.inputKind !== 'steer'),
      last(childRows, item => item.inputKind !== 'steer' && item.taskID),
      last(childRows, item => item.admission !== 'attached'),
      childRows.at(-1)
    ]) if (row) keep.add(row);
  }
  for (const row of rows) {
    if (isFinished(row)) continue;
    for (const dependency of row.dependencies ?? []) {
      const target = rows.find(item => item.childID === dependency.childID && item.requestID === dependency.requestID);
      if (target) keep.add(target);
    }
    if (row.pendingOperation !== 'send' && !row.previousRequestID) continue;
    const siblings = byChild.get(row.childID) ?? [];
    const previous = row.previousRequestID
      ? siblings.find(item => item.requestID === row.previousRequestID)
      : siblings.slice(0, siblings.indexOf(row)).findLast(item => item.inputKind !== 'steer');
    if (previous) keep.add(previous);
  }
  return keep;
}

/**
 * Stamps newly finished records with `settledAt` and removes those that are finished, delivered, superseded,
 * unreferenced by unfinished work and older than `retentionMs`. Mutates `bindings` in place because long-running
 * waiters hold the array. Returns whether anything changed and needs to be persisted.
 */
export function retireBindings(bindings, rootSessionID, { now = Date.now(), isBusy = () => false } = {}) {
  const rows = bindings.filter(row => row.rootSessionID === rootSessionID);
  let changed = false;
  for (const row of rows) {
    if (!isFinished(row)) {
      if (row.settledAt !== undefined) { delete row.settledAt; changed = true; }
    } else if (row.settledAt === undefined) {
      // Existing files carry no stamp, so their retention window starts when this version first sees them.
      row.settledAt = now;
      changed = true;
    }
  }
  const keep = protectedRows(rows);
  const expired = new Set(rows.filter(row => !keep.has(row) && isFinished(row) && !isBusy(row) &&
    now - row.settledAt >= retentionMs));
  if (!expired.size) return changed;
  for (let index = bindings.length - 1; index >= 0; index--) if (expired.has(bindings[index])) bindings.splice(index, 1);
  return true;
}
