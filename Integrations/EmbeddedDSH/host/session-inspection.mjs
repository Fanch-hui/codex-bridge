export async function inspectSession(ctx, sessionId, signal) {
  const observation = await ctx.sessionQuery.observeSession(sessionId, {
    projectionMode: 'none', ...(signal ? { signal } : {})
  });
  try {
    return { meta: observation.header, inheritedEventCount: observation.inheritedEventCount,
      cursor: observation.cursor };
  } finally {
    observation[Symbol.dispose]();
  }
}
