import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readReleaseConfiguration, registryMetadata, verifyRegistryMetadata } from './mcpb-release-metadata.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const [bundle, metadata, tag, repository] = process.argv.slice(2);
assert(bundle && metadata && tag,
  'Usage: node Scripts/verify-mcpb-release.mjs <bundle> <server.json> <release-tag> [owner/repo]');
const configuration = await readReleaseConfiguration(root);
assert.equal(tag, `v${configuration.version}`, 'Release tag must match the app version');
if (repository) assert.equal(repository, configuration.repositoryName, 'Release repository must match');
const server = JSON.parse(await readFile(metadata, 'utf8'));
verifyRegistryMetadata(server, await registryMetadata(configuration, bundle));
const manifest = JSON.parse(execFileSync('unzip', ['-p', resolve(bundle), 'manifest.json'], {
  encoding: 'utf8', maxBuffer: 1024 * 1024,
}));
assert.equal(manifest.version, configuration.version, 'Bundled manifest version must match');
assert.equal(manifest.name, configuration.manifest.name, 'Bundled identity must match');
assert.equal(manifest.repository?.url, configuration.manifest.repository.url, 'Bundled repository must match');
console.log(`MCPB ${configuration.version}: release identity, bundled manifest and SHA-256 verified.`);
