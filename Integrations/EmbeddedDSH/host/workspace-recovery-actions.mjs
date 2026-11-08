export class WorkspaceRecoveryActions {
  constructor(writes, sessions) {
    this.writes = writes;
    this.sessions = sessions;
  }

  async call(action, payload) {
    switch (action) {
      case 'workspace.recovery.list': return this.writes.recoveryList();
      case 'workspace.recovery.check': return this.writes.recoveryCheck(payload);
      case 'workspace.recovery.terminate': return this.writes.recoveryTerminate(payload);
      case 'workspace.recovery.confirmLegacy': return this.writes.recoveryConfirmLegacy(payload);
      case 'workspace.recovery.resume': return this.resume(payload);
      default: throw new Error('Unknown workspace recovery action');
    }
  }

  async resume({ sessionId, recoveryID }) {
    const state = await this.writes.recoveryCheck({ sessionId, recoveryID });
    const item = state.items.find(row => row.sessionId === sessionId &&
      (recoveryID === undefined || row.recoveryID === recoveryID));
    if (!item || item.status !== 'exited' || item.canResume === false) {
      throw new Error('Finish workspace recovery before resuming the task');
    }
    const agent = await this.sessions.agent(sessionId);
    const source = agent.session.snapshotEvents().findLast(event =>
      event.type === 'user/message' && event.data?.source?.kind === 'user')?.data?.source;
    if (typeof source?.rpcId !== 'string') {
      await this.writes.recoveryAcknowledge({ sessionId, recoveryID });
      return { sessionId, resumed: false };
    }
    const revision = this.sessions.stopGate.revision(sessionId);
    await this.sessions.stopGate.resume(sessionId, revision);
    const result = await this.sessions.resumePending({ sessionId, requestId: source.rpcId });
    await this.writes.recoveryAcknowledge({ sessionId, recoveryID });
    return { ...result, sessionId };
  }
}
