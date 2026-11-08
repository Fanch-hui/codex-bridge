const initialActions = new Set([
  'status', 'events', 'auth.status', 'models.list', 'session.list', 'session.history',
  'session.content', 'session.scope', 'permissions.get', 'pending.list', 'context.get', 'context.bind'
]);

export function startActions(actions) {
  const initial = (async () => {
    await actions.contextPolicy.start();
    await actions.activation.start();
    await actions.pluginOperations.start();
    await actions.clientEvents.start();
    await actions.sessions.start();
    await actions.contentCache.start();
    await actions.scopes.start();
    await actions.writes.start();
    await actions.scheduleOperations.start();
    await actions.persistedQuestions.start();
    actions.connections.start();
    return actions;
  })();
  const complete = initial.then(async () => {
    await actions.mcp.start();
    await actions.bridgeAgents.start();
    await actions.activity.start();
    await actions.verifyRestartedPlugins();
    return actions;
  });
  return { initial, complete };
}

export async function callWhenReady(startup, action, payload, signal) {
  const ready = initialActions.has(action) ? startup.initial : startup.complete;
  signal?.throwIfAborted();
  const actions = signal ? await new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason);
    signal.addEventListener('abort', abort, { once: true });
    ready.then(value => {
      signal.removeEventListener('abort', abort);
      resolve(value);
    }, error => {
      signal.removeEventListener('abort', abort);
      reject(error);
    });
  }) : await ready;
  signal?.throwIfAborted();
  return actions.call(action, payload, signal);
}
