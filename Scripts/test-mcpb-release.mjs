import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { appendFile, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { readReleaseConfiguration, registryMetadata } from './mcpb-release-metadata.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

test('MCPB release verification checks the real archive, version and checksum', async () => {
  const configuration = await readReleaseConfiguration(root);
  const directory = await mkdtemp(join(tmpdir(), 'bridge-mcpb-metadata-'));
  const artifact = join(directory, `codex-bridge-${configuration.version}.mcpb`);
  const metadata = join(directory, 'server.json');
  const verify = () => execFileSync(process.execPath, [
    join(root, 'Scripts', 'verify-mcpb-release.mjs'), artifact, metadata,
    `v${configuration.version}`, configuration.repositoryName,
  ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  try {
    await writeFile(join(directory, 'manifest.json'), JSON.stringify(configuration.manifest));
    execFileSync('zip', ['-q', artifact, 'manifest.json'], { cwd: directory });
    await writeFile(metadata, JSON.stringify(await registryMetadata(configuration, artifact)));
    assert.match(verify(), /SHA-256 verified/);

    await appendFile(artifact, 'changed');
    assert.throws(verify, error => error.stderr.toString().includes('fileSha256'));

    await rm(artifact);
    await writeFile(join(directory, 'manifest.json'), JSON.stringify({
      ...configuration.manifest, version: '0.0.0',
    }));
    execFileSync('zip', ['-q', artifact, 'manifest.json'], { cwd: directory });
    await writeFile(metadata, JSON.stringify(await registryMetadata(configuration, artifact)));
    assert.throws(verify, error => error.stderr.toString().includes('Bundled manifest version'));
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
