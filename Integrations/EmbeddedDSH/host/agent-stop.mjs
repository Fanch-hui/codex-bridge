/**
 * Runs every stop request independently. A failing child never prevents the others from being stopped;
 * all failures are collected and returned so the caller can report them once the rest of the stop is done.
 */
export async function settleStops(bindings, requestStop) {
  const outcomes = await Promise.allSettled(bindings.map(binding => requestStop(binding)));
  return outcomes.flatMap((outcome, index) => outcome.status === 'rejected'
    ? [{ childID: bindings[index].childID, error: outcome.reason }] : []);
}

export function stopFailure(failures) {
  const detail = failures.map(({ childID, error }) => `${childID ?? 'subagent'}: ${error?.message ?? error}`).join('; ');
  return new AggregateError(failures.map(item => item.error),
    `Failed to stop ${failures.length} subagent request${failures.length === 1 ? '' : 's'}: ${detail}`);
}
