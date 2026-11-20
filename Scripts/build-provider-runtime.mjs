import { spawn } from 'node:child_process';
import { cp, mkdir } from 'node:fs/promises';
import { join } from 'node:path';

export async function buildProviderRuntime({ root, stage, platform, architecture, node, npmCLI, npmConfig, globalNpmConfig }) {
  const destination = join(stage, 'provider');
  const community = join(destination, 'community');
  const editor = join(destination, 'agent-connections');
  const communitySource = join(root, 'Integrations', 'CommunityProviders');
  const editorSource = join(root, 'Integrations', 'AgentConnections');
  await mkdir(community, { recursive: true });
  await mkdir(editor, { recursive: true });
  for (const file of ['catalog.json', 'install.mjs', 'provision-bun.mjs', 'cli.mjs']) {
    await cp(join(communitySource, file), join(community, file));
  }
  for (const file of ['host.js', 'bridge-secret.js', 'LICENSE']) {
    await cp(join(communitySource, 'vendor', 'magpie', file), join(community, file));
  }
  for (const file of ['index.mjs', 'connections.mjs', 'editor.mjs', 'package.json', 'package-lock.json']) {
    await cp(join(editorSource, file), join(editor, file));
  }
  await run(node, [npmCLI, 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund',
    '--userconfig', npmConfig, '--globalconfig', globalNpmConfig,
    '--os', platform === 'windows' ? 'win32' : platform, '--cpu', architecture], editor);
  await cp(join(root, 'Integrations', 'ModelProtocol', 'LICENSE'), join(destination, 'MODEL_PROTOCOL_LICENSE'));
  const executable = join(destination, platform === 'windows' ? 'model-protocol.exe' : 'model-protocol');
  await run(process.env.GO || 'go', ['build', '-buildvcs=false', '-trimpath', '-mod=readonly', '-o', executable, './cmd/model-protocol'],
    join(root, 'Integrations', 'ModelProtocol'), {
      CGO_ENABLED: '0', GOTOOLCHAIN: 'local', GOOS: platform === 'windows' ? 'windows' : platform,
      GOARCH: architecture === 'x64' ? 'amd64' : 'arm64'
    });
}

function run(executable, args, cwd, overrides = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { cwd, env: { ...process.env, ...overrides }, stdio: 'inherit' });
    child.once('error', reject);
    child.once('exit', code => code === 0 ? resolve() : reject(new Error(`${executable} exited ${code}`)));
  });
}
