// Exponential retry pacing for pollers that must keep trying but should not hammer a busy or restarting service.
export class Backoff {
  constructor({ initialMs, maxMs }) {
    this.initialMs = initialMs;
    this.maxMs = maxMs;
    this.attempts = 0;
  }
  /** Pause before the next attempt; every call counts as one more consecutive failure. */
  next() {
    const pause = Math.min(this.maxMs, this.initialMs * 2 ** this.attempts);
    this.attempts += 1;
    return pause;
  }
  /** Forget earlier failures after a success; returns how many there were. */
  reset() {
    const failures = this.attempts;
    this.attempts = 0;
    return failures;
  }
  /** True on the 1st, 2nd, 4th, 8th... consecutive failure, so a long outage logs only a handful of lines. */
  get shouldReport() {
    return (this.attempts & (this.attempts - 1)) === 0;
  }
}
