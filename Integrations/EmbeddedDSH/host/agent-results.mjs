/**
 * Remembers which results Bridge could not describe, so a child that stays unreadable is reported
 * once rather than on every poll. Bridge keeps returning the others and the child comes back
 * when it can be described.
 */
export class SkippedResults {
  constructor() { this.reported = new Map(); }

  report(rootSessionID, skipped = []) {
    const current = new Set();
    const before = this.reported.get(rootSessionID);
    for (const item of skipped) {
      const key = JSON.stringify([item.childID, item.requestID, item.error]);
      current.add(key);
      if (before?.has(key)) continue;
      process.stderr.write(`DSH subagent result skipped (child ${item.childID}, request ${item.requestID}): ${item.error}\n`);
    }
    if (current.size) this.reported.set(rootSessionID, current); else this.reported.delete(rootSessionID);
  }
}
