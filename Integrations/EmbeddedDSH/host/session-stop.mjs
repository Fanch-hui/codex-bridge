/**
 * Counts the stop requests in progress per session. `stopStatus` reports it, so the Bridge can tell
 * a stop that is still working from one that was never delivered or failed, and resend only the latter.
 */
export async function trackStop(flights, id, work) {
  flights.set(id, (flights.get(id) ?? 0) + 1);
  try { return await work(); }
  finally {
    const remaining = (flights.get(id) ?? 1) - 1;
    if (remaining > 0) flights.set(id, remaining); else flights.delete(id);
  }
}

/**
 * Stops a session, then cancels its scopes. The scopes are cancelled even when the stop throws, so
 * a failed stop cannot leave late work running under the session; the stop's own error is the one
 * the caller sees.
 */
export async function stopWithScopes(sessions, scopes, sessionId) {
  let result;
  try { result = await sessions.stop(sessionId); }
  catch (error) {
    try { await scopes.cancel(sessionId); }
    catch (cancelError) { process.stderr.write(`DSH scope cancel failed after a failed stop: ${cancelError.message}\n`); }
    throw error;
  }
  await scopes.cancel(sessionId);
  return result;
}
