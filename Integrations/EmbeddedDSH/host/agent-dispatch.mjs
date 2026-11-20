import { createUserMessage, freezeMessage } from '@deepseek-ai/dsh-llm';
import { recordChild } from './agent-delivery.mjs';
import { recordNotice } from './agent-notices.mjs';

const summaryLimit = 120;

const noticeID = (childID, requestID) => `bridge-dispatch:${JSON.stringify([childID, requestID])}`;

const required = (name, value) => {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} is required`);
  return value;
};

/** The fields of a direct hand-over, checked. */
export function dispatchRequest(p) {
  return { rootSessionID: required('sessionId', p.sessionId), childID: required('childId', p.childId),
    requestID: required('requestId', p.requestId), installationID: required('installationID', p.installationID),
    text: required('text', p.text),
    ...(p.model ? { model: p.model } : {}), ...(p.effort ? { effort: p.effort } : {}),
    ...(p.attachmentPaths?.length ? { attachmentPaths: p.attachmentPaths } : {}),
    ...(typeof p.label === 'string' && p.label.trim() ? { label: p.label.trim() } : {}) };
}

/** Records the hand-over in the parent session for the next user prompt. */
export function recordDispatch(parent, { childID, requestID, installationID, name, text }) {
  recordChild(parent, { childID, label: name });
  const id = noticeID(childID, requestID);
  const summary = `用户直接交给 ${name}`.slice(0, summaryLimit);
  const message = createUserMessage({
    content: [{ type: 'text', text: `用户直接交给 ${name}：${text}\n（Bridge 子 Agent ${childID}，请求 ${requestID}；完成后结果会另行送达。）` }],
    source: { kind: 'subagent-dispatch', form: 'notice', summary, senderSessionId: childID, installationID, requestId: requestID } });
  recordNotice(parent.session, freezeMessage({ ...message, id }));
}
