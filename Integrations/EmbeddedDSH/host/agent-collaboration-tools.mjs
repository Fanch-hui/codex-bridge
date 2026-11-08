import { defineTool } from '@deepseek-ai/dsh-tools';
import { dependenciesFor, handoffPrompt, waitForDependencies } from './agent-handoff.mjs';

export const handoffParameters = {
  context: { type: 'string', description: 'Task-specific context needed by the child.' },
  scope: { type: 'string', description: 'The files or responsibilities assigned to the child.' },
  dependsOn: { type: 'array', items: { type: 'string' }, description: 'Connected child IDs whose successful changes must be merged before this task starts.' },
  attachmentPaths: { type: 'array', items: { type: 'string' }, description: 'Project-relative image paths to include; the selected provider must support images.' }
};

const output = { schema: { type: 'string' }, render: (_args, text) => [{ type: 'text', text }] };

export function registerCollaborationTools(bridge) {
  const { ctx } = bridge;
  const register = (name, description, parameters, execute) => ctx.tools.register(defineTool({
    name, description, parameters, output, isConcurrencySafe: () => true, execute
  }));
  register('delegate_agent', 'Start a native or connected subagent. Include task-specific context only; do not include credentials, private reasoning, or MCP operating instructions. Results arrive when the child finishes.', {
    description: { type: 'string', required: true }, prompt: { type: 'string', required: true },
    installationID: { type: 'string', description: 'Connected agent installation ID. Omit for a native child.' },
    model: { type: 'string' }, effort: { type: 'string' }, ...handoffParameters
  }, async (args, exec) => {
    if (!exec.agent) throw new Error('Delegation requires an agent');
    if (args.installationID) return bridge.delegate(args, exec);
    if (args.attachmentPaths?.length) throw new Error('Native delegation does not support attachment paths');
    if (args.model || args.effort) throw new Error('Select a native child model through the native subagent tool');
    const rootSessionID = bridge.rootOf(exec.agent);
    const dependencies = dependenciesFor(bridge.bindings, rootSessionID, args.dependsOn);
    await waitForDependencies({ rootSessionID, dependencies }, bridge.bindings, bridge.rpc, exec.signal, async () => {});
    const native = ctx.tools.get('subagent', exec.agent);
    if (!native) throw new Error('Native subagent tool is unavailable');
    return JSON.stringify(await native.execute({ description: args.description, prompt: handoffPrompt(args) }, exec));
  });
  register('list_child_agents', 'List native and connected subagents started by this agent.', {
    scope: { type: 'string', enum: ['children', 'descendants'] }
  }, async (args, exec) => {
    if (!exec.agent) throw new Error('Listing subagents requires an agent');
    const id = exec.agent.session.id;
    const rows = args.scope === 'descendants' ? await ctx.subagents.listDescendants(id, exec.signal)
      : await ctx.subagents.listChildren(id, exec.signal);
    return JSON.stringify(rows.map(row => {
      const binding = [...bridge.bindings].reverse().find(item => item.childID === row.id && item.inputKind !== 'steer');
      return { ...row, ...(binding ? { installationID: binding.installationID, taskID: binding.taskID,
        state: binding.state, workspaceMode: binding.workspaceMode, workspaceStatus: binding.workspaceStatus } : {}) };
    }));
  });
  register('send_agent_message', 'Message a native or connected direct child. Queue a connected continuation or steer only when supported.', {
    childID: { type: 'string', required: true }, prompt: { type: 'string', required: true },
    delivery: { type: 'string', enum: ['queue', 'steer'] }, attachmentPaths: handoffParameters.attachmentPaths,
    repairConflict: { type: 'boolean', description: 'Explicitly ask the child to repair its conflicted workspace.' }
  }, async (args, exec) => {
    if (!exec.agent) throw new Error('Messaging a subagent requires an agent');
    const parentID = exec.agent.session.id;
    const binding = bridge.bindings.find(row => row.childID === args.childID && row.parentSessionID === parentID);
    if (binding) return JSON.stringify(await bridge.send(args.childID, args.prompt,
      bridge.continuationID(bridge.rootOf(exec.agent), args.childID, exec.callId), bridge.rootOf(exec.agent),
      { delivery: args.delivery, attachmentPaths: args.attachmentPaths, repairConflict: args.repairConflict }));
    if (args.attachmentPaths?.length || args.delivery === 'queue' || args.repairConflict) throw new Error('This native tool does not support queued messages, attachment paths, or workspace repair');
    const native = ctx.tools.get('send_message', exec.agent);
    if (!native) throw new Error('Native subagent messaging is unavailable');
    return JSON.stringify(await native.execute({ agent_id: args.childID, message: args.prompt }, exec));
  });
  register('stop_child_agent', 'Stop a native or connected descendant subagent.', {
    childID: { type: 'string', required: true }
  }, async (args, exec) => {
    if (!exec.agent) throw new Error('Stopping a subagent requires an agent');
    const descendants = await ctx.subagents.listDescendants(exec.agent.session.id, exec.signal);
    if (!descendants.some(row => row.kind === 'child' && row.id === args.childID)) throw new Error('Subagent is not a descendant');
    const binding = bridge.bindings.find(row => row.childID === args.childID);
    if (binding) return JSON.stringify(await bridge.stop(args.childID, bridge.rootOf(exec.agent)));
    const native = ctx.tools.get('interrupt_agent', exec.agent);
    if (!native) throw new Error('Native subagent interruption is unavailable');
    return JSON.stringify(await native.execute({ agent_id: args.childID }, exec));
  });
}

export function registerBridgeTools(bridge) {
  const register = (name, description, parameters, execute) => bridge.ctx.tools.register(defineTool({
    name, description, parameters, output, isConcurrencySafe: () => true, execute
  }));
  register('bridge_agents', 'List available connected agents for delegation.', {}, async (_args, exec) => JSON.stringify(await bridge.agents(exec.agent)));
  register('bridge_agent_models', 'List models for a connected agent.', { installationID: { type: 'string', required: true } },
    async (args, exec) => JSON.stringify(await bridge.rpc.request('bridge/agentModels', { sessionID: bridge.rootOf(exec.agent), installationID: args.installationID })));
  register('bridge_delegate', 'Start an independent connected agent. Include task-specific context only; do not include credentials, private reasoning, or MCP operating instructions. Its result and workspace status are delivered to you.', {
    installationID: { type: 'string', required: true }, description: { type: 'string', required: true },
    prompt: { type: 'string', required: true }, model: { type: 'string' }, effort: { type: 'string' }, ...handoffParameters
  }, (args, exec) => bridge.delegate(args, exec));
  register('bridge_send_agent', 'Send another instruction to a running or finished connected subagent.', {
    childID: { type: 'string', required: true }, prompt: { type: 'string', required: true },
    delivery: { type: 'string', enum: ['queue', 'steer'] }, attachmentPaths: handoffParameters.attachmentPaths,
    repairConflict: { type: 'boolean', description: 'Explicitly ask the child to repair its conflicted workspace.' }
  }, async (args, exec) => {
    const root = bridge.rootOf(exec.agent);
    return JSON.stringify(await bridge.send(args.childID, args.prompt, bridge.continuationID(root, args.childID, exec.callId), root,
      { delivery: args.delivery, attachmentPaths: args.attachmentPaths, repairConflict: args.repairConflict }));
  });
  register('bridge_stop_agent', 'Stop a connected subagent.', { childID: { type: 'string', required: true } },
    async (args, exec) => JSON.stringify(await bridge.stop(args.childID, bridge.rootOf(exec.agent))));
  register('bridge_agent_changes', 'Inspect a connected agent\'s proposed changes or retry their merge. After resolving a conflict in the project, submit its relative path and current SHA-256 in resolutions; use null for a deleted file.', {
    childID: { type: 'string', required: true }, retryMerge: { type: 'boolean' },
    resolutions: { type: 'array', items: { type: 'object', additionalProperties: false, properties: {
      relativePath: { type: 'string', required: true },
      expectedSHA256: { required: true, oneOf: [{ type: 'string' }, { type: 'null' }] }
    } } }
  }, async (args, exec) => {
    const rootSessionID = bridge.rootOf(exec.agent);
    if (!bridge.bindings.some(row => row.rootSessionID === rootSessionID && row.childID === args.childID)) {
      throw new Error('Bridge subagent not found');
    }
    return JSON.stringify(await bridge.rpc.request('bridge/subagent', { operation: 'changes', rootSessionID,
      childID: args.childID, ...(args.retryMerge === undefined ? {} : { retryMerge: args.retryMerge }),
      ...(args.resolutions === undefined ? {} : { resolutions: args.resolutions }) }));
  });
}
