import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'Integrations', 'MCPB');
const output = resolve(process.argv[2] ?? join(root, '.build', 'mcp-registry'));
const manifest = JSON.parse(await readFile(join(source, 'manifest.json'), 'utf8'));
const stage = await mkdtemp(join(tmpdir(), 'codex-bridge-mcpb-'));
const registryName = 'io.github.yeyuancc0-glitch/codex-bridge';
const repository = 'https://github.com/yeyuancc0-glitch/codex-bridge';

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: stage,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`);
}

try {
  await mkdir(output, { recursive: true });
  for (const name of ['manifest.json', 'package.json', 'package-lock.json', 'server.mjs']) {
    await copyFile(join(source, name), join(stage, name));
  }
  await copyFile(join(root, 'LICENSE'), join(stage, 'LICENSE'));
  await copyFile(join(root, 'docs', 'MCP_REGISTRY.md'), join(stage, 'README.md'));
  run('npm', ['ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund']);
  const artifactName = `codex-bridge-${manifest.version}.mcpb`;
  const artifact = join(output, artifactName);
  run('npx', ['--yes', '@anthropic-ai/mcpb@2.1.2', 'pack', stage, artifact]);
  const digest = createHash('sha256').update(await readFile(artifact)).digest('hex');
  const server = {
    $schema: 'https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json',
    name: registryName,
    title: 'Codex Bridge',
    description: 'Connect MCP clients to local Codex Bridge agents, projects, approvals and workspace tools.',
    repository: { url: repository, source: 'github' },
    websiteUrl: `${repository}#readme`,
    version: manifest.version,
    packages: [{
      registryType: 'mcpb',
      identifier: `${repository}/releases/download/v${manifest.version}/${artifactName}`,
      fileSha256: digest,
      transport: { type: 'stdio' },
    }],
  };
  await writeFile(join(output, 'server.json'), `${JSON.stringify(server, null, 2)}\n`);
  console.log(`MCPB: ${artifactName}\nSHA-256: ${digest}`);
} finally {
  await rm(stage, { recursive: true, force: true });
}
