import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

export async function readReleaseConfiguration(root) {
  const source = join(root, 'Integrations', 'MCPB');
  const readJSON = async name => JSON.parse(await readFile(join(source, name), 'utf8'));
  const [manifest, packageMetadata, lock, configuration] = await Promise.all([
    readJSON('manifest.json'), readJSON('package.json'), readJSON('package-lock.json'),
    readFile(join(root, 'Config', 'Base.xcconfig'), 'utf8'),
  ]);
  const version = configuration.match(/^MARKETING_VERSION\s*=\s*(\d+\.\d+\.\d+)\s*$/m)?.[1];
  if (!version || [manifest.version, packageMetadata.version, lock.version, lock.packages[''].version]
    .some(value => value !== version)) {
    throw new Error('App, MCPB manifest, package and lockfile versions must match');
  }
  const repository = manifest.repository.url.replace(/\.git$/, '');
  const url = new URL(repository);
  if (url.origin !== 'https://github.com' || !/^\/[^/]+\/[^/]+$/.test(url.pathname) ||
      manifest.homepage !== repository || manifest.support !== `${repository}/issues`) {
    throw new Error('MCPB repository links must identify the same GitHub repository');
  }
  return { manifest, version, repository, repositoryName: url.pathname.slice(1) };
}

export async function registryMetadata(configuration, artifact) {
  const { version, repository, repositoryName } = configuration;
  const digest = createHash('sha256').update(await readFile(artifact)).digest('hex');
  return {
    $schema: 'https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json',
    name: `io.github.${repositoryName}`,
    title: 'Codex Bridge',
    description: 'Connect MCP clients to local Codex Bridge agents, projects, approvals and workspace tools.',
    repository: { url: repository, source: 'github' },
    websiteUrl: `${repository}#readme`,
    version,
    packages: [{
      registryType: 'mcpb',
      identifier: `${repository}/releases/download/v${version}/codex-bridge-${version}.mcpb`,
      fileSha256: digest,
      transport: { type: 'stdio' },
    }],
  };
}

export function verifyRegistryMetadata(actual, expected) {
  for (const key of ['$schema', 'name', 'version', 'websiteUrl']) {
    if (actual[key] !== expected[key]) throw new Error(`Registry ${key} does not match this release`);
  }
  if (actual.repository?.url !== expected.repository.url ||
      actual.repository?.source !== 'github' || actual.packages?.length !== 1) {
    throw new Error('Registry repository or package list does not match this release');
  }
  const actualPackage = actual.packages[0];
  const expectedPackage = expected.packages[0];
  for (const key of ['registryType', 'identifier', 'fileSha256']) {
    if (actualPackage[key] !== expectedPackage[key]) {
      throw new Error(`Registry package ${key} does not match the release artifact`);
    }
  }
  if (actualPackage.transport?.type !== 'stdio') throw new Error('MCPB transport must be stdio');
}
