import { installProvider } from '../Integrations/CommunityProviders/install.mjs';

const [bun, root, name, version] = process.argv.slice(2);
try {
  const result = await installProvider({ bun, root, name, version });
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
