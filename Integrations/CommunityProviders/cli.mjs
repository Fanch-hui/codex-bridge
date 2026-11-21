import { installProvider, latestProviderVersion, removeProvider } from './install.mjs';
import { provisionBun } from './provision-bun.mjs';

try {
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk;
    if (input.length > 65536) throw new Error('Request is too large');
  }
  const request = JSON.parse(input);
  let result;
  if (request.action === 'prepareBun') result = await provisionBun(request.root);
  else if (request.action === 'install') {
    // Bun is provisioned only when the package comes from npm; bundled plugins install offline.
    result = await installProvider({
      bun: async () => (await provisionBun(request.root)).path,
      root: request.root, name: request.name, version: request.version
    });
  } else if (request.action === 'remove') result = await removeProvider({ root: request.root, name: request.name });
  else if (request.action === 'latest') result = await latestProviderVersion(request.name);
  else throw new Error('Unknown provider installation action');
  process.stdout.write(JSON.stringify({ result }) + '\n');
} catch (error) {
  process.stdout.write(JSON.stringify({ error: error.message }) + '\n');
  process.exitCode = 1;
}
