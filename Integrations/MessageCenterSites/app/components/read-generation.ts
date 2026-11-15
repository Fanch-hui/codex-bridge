// A read may only write its response into state while it is still the newest
// view of the data. Starting another read, or a successful write to the same
// scope, retires every earlier read so a late response cannot overwrite it.
export function createReadGeneration() {
  let generation = 0;
  let activeScope: string | undefined;
  return {
    // Returns a check to call once the response arrives. `scope` names the
    // record the read is about (omit it for a whole list).
    startRead(scope?: string): () => boolean {
      const issued = ++generation;
      activeScope = scope;
      return () => issued === generation;
    },
    // Call after a write succeeded. Reads of other scopes are unaffected, so a
    // late receipt for one record cannot discard the read of the record now shown.
    invalidateReads(scope?: string): void {
      if (scope === activeScope) generation += 1;
    },
  };
}
