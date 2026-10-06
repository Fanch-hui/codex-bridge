import { randomUUID } from 'node:crypto';
import { fault } from './errors.mjs';

export class Interactions {
  constructor(runs) { this.runs = runs; this.pending = new Map(); }
  async ask(type, request, next) {
    const run = request.agent && this.runs.currentRun(request.agent);
    if (!run) return next();
    const interactionID = randomUUID();
    const data = type === 'approval'
      ? { interactionID, toolName: request.toolName, ...(request.reason ? { reason: request.reason } : {}) }
      : { interactionID, questions: request.questions };
    this.runs.append(run, type, data);
    await this.runs.store.save();
    return new Promise(resolve => {
      const finish = value => {
        this.pending.delete(interactionID);
        request.signal?.removeEventListener('abort', aborted);
        resolve(value);
      };
      const aborted = () => finish(type === 'approval' ? 'cancelled' : { answers: [] });
      this.pending.set(interactionID, { run, type, finish });
      if (request.signal?.aborted) aborted();
      else request.signal?.addEventListener('abort', aborted, { once: true });
    });
  }
  answer(params, key) {
    const run = this.runs.owned(params.requestID, key);
    const pending = this.pending.get(params.interactionID);
    if (!pending || pending.run !== run) throw fault('interaction_expired', 'Interaction is no longer pending');
    let answer;
    if (pending.type === 'approval') {
      if (!['allow', 'reject'].includes(params.answer?.decision)) throw fault('invalid_answer', 'Approval decision must be allow or reject');
      answer = params.answer.decision === 'allow' ? 'allowed-once' : 'rejected';
    } else {
      if (!Array.isArray(params.answer?.answers) || params.answer.answers.some(item => typeof item.id !== 'string' || !Array.isArray(item.selected) || item.selected.some(value => typeof value !== 'string') || item.custom !== undefined && typeof item.custom !== 'string')) throw fault('invalid_answer', 'Invalid structured question answers');
      answer = params.answer;
    }
    pending.finish(answer);
    return { accepted: true };
  }
  close() { for (const value of [...this.pending.values()]) value.finish(value.type === 'approval' ? 'cancelled' : { answers: [] }); }
}
