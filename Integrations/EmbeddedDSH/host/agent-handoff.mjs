import { setTimeout as delay } from 'node:timers/promises';

export function handoffPrompt({ prompt, context, scope }) {
  return [prompt, context && `Context:\n${context}`, scope && `Scope:\n${scope}`].filter(Boolean).join('\n\n');
}

/** Waits until the named connected children finished and merged; the Service decides when that is. */
export async function waitForDependencies(bridge, rootSessionID, childIDs, signal) {
  if (!childIDs?.length) return;
  let dependencies;
  for (;;) {
    signal?.throwIfAborted();
    const readiness = await bridge.dependencies(rootSessionID, childIDs, dependencies);
    dependencies ??= readiness.dependencies;
    if (readiness.state === 'ready') return;
    if (readiness.state !== 'waiting') throw new Error(readiness.reason);
    await delay(1000, undefined, { signal });
  }
}
