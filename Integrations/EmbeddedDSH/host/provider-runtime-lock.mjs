import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { withFileLock } from '@deepseek-ai/dsh-atomic-write';

export async function acquireProviderRuntime(home, role = 'provider') {
  await mkdir(home, { recursive: true });
  const acquired = Promise.withResolvers();
  const released = Promise.withResolvers();
  const lock = role === 'shared-workbench' ? 'bridge-shared-workbench-runtime' : 'bridge-provider-runtime';
  const held = withFileLock(join(home, lock), async () => {
    acquired.resolve();
    await released.promise;
  }, { waitMs: 2000 });
  void held.catch(acquired.reject);
  await acquired.promise;
  return async () => {
    released.resolve();
    await held;
  };
}
