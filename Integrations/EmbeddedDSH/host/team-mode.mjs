// Per-session Agent Teams selection. Upstream keeps it off until a root session turns it on, so the
// Bridge desktop UI calls this action; the engine persists the `team/mode` event and projects it as `agentTeam`.
const leadRequired = 'TEAM_LEAD_REQUIRED';

export async function setTeamMode(ctx, sessions, payload) {
  if (typeof payload.sessionId !== 'string' || !payload.sessionId || typeof payload.enabled !== 'boolean') {
    throw new Error('团队协作设置无效，请重试。');
  }
  const teams = ctx.get('agentTeams');
  if (!teams) throw new Error('当前引擎不支持团队协作。');
  const agent = await sessions.agent(payload.sessionId);
  try {
    await teams.setEnabled(agent, payload.enabled);
  } catch (error) {
    if (error?.code === leadRequired) throw new Error('只能在主会话中切换团队协作。', { cause: error });
    throw error;
  }
  return { enabled: payload.enabled };
}
