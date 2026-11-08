#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync } from 'node:fs';
import { cp, lstat, mkdir, mkdtemp, readFile, readdir, readlink, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, delimiter, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { patchScheduleAdmission } from './embedded-dsh-schedule-patch.mjs';
import { patchSessionController } from './embedded-dsh-session-patch.mjs';
import { patchSessionPersistence, patchSessionQuery } from './embedded-dsh-persistence-patch.mjs';
import { patchSiwc } from './embedded-dsh-siwc-patch.mjs';
import { patchContextCompaction, patchContextAgentLoop } from './patch-embedded-dsh-context.mjs';

const version = '24.11.1';
const hashes = {
  'darwin-arm64': 'b05aa3a66efe680023f930bd5af3fdbbd542794da5644ca2ad711d68cbd4dc35',
  'darwin-x64': '096081b6d6fcdd3f5ba0f5f1d44a47e83037ad2e78eada26671c252fe64dd111',
  'linux-arm64': '0dc93ec5c798b0d347f068db6d205d03dea9a71765e6a53922b682b91265d71f',
  'linux-x64': '58a5ff5cc8f2200e458bea22e329d5c1994aa1b111d499ca46ec2411d58239ca',
  'windows-arm64': 'ce9ee4e547ebdff355beb48e309b166c24df6be0291c9eaf103ce15f3de9e5b4',
  'windows-x64': '5355ae6d7c49eddcfde7d34ac3486820600a831bf81dc3bdca5c8db6a9bb0e76'
};
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'Integrations', 'EmbeddedDSH');
const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, item, index, all) => {
  if (index % 2 === 0) pairs.push([item, all[index + 1]]);
  return pairs;
}, []));
const platform = args['--platform'];
const architecture = args['--arch'];
const destination = args['--output'];
const expected = hashes[`${platform}-${architecture}`];
if (!expected || !destination || !isAbsolute(destination)) {
  throw new Error('Usage: build-embedded-dsh-runtime.mjs --platform darwin|linux|windows --arch arm64|x64 --output ABSOLUTE_NEW_DIRECTORY');
}
try { await lstat(destination); throw new Error(`Output already exists: ${destination}`); }
catch (error) { if (error.code !== 'ENOENT') throw error; }

const temporary = await mkdtemp(join(tmpdir(), 'bridge-dsh-build-'));
const stage = join(temporary, 'runtime');
try {
  await mkdir(stage, { recursive: true });
  await Promise.all(['package.json', 'package-lock.json'].map(file => cp(join(source, file), join(stage, file))));
  await cp(join(source, 'host'), join(stage, 'host'), { recursive: true });
  await cp(join(source, 'licenses'), join(stage, 'licenses'), { recursive: true });
  await cp(join(source, 'vendor'), join(stage, 'vendor'), { recursive: true });
  await cp(join(source, 'upstream.json'), join(stage, 'upstream.json'));
  const upstream = JSON.parse(await readFile(join(stage, 'upstream.json'), 'utf8'));
  for (const plugin of [upstream.zcode, upstream.workbuddy]) {
    if (await digest(join(stage, plugin.archive)) !== plugin.sha256) throw new Error(`Bundled plugin checksum mismatch: ${plugin.package}`);
  }
  const npmConfig = join(temporary, 'npmrc');
  const globalNpmConfig = join(temporary, 'global-npmrc');
  await Promise.all([writeFile(npmConfig, ''), writeFile(globalNpmConfig, '')]);
  const npmCLI = [
    join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    join(dirname(process.execPath), '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    ...String(process.env.PATH ?? '').split(delimiter).map(path => join(path, '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js'))
  ].find(existsSync);
  if (!npmCLI) throw new Error('Node npm-cli.js was not found');
  await command(process.execPath, [npmCLI,
    'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund', '--userconfig', npmConfig,
    '--globalconfig', globalNpmConfig, '--os', platform === 'windows' ? 'win32' : platform, '--cpu', architecture
  ], stage);
  await patchIdentity(join(stage, 'node_modules', 'dsh-plugin-chatgpt-siwc', 'lib', 'auth', 'index.js'));
  await patchSiwc(join(stage, 'node_modules', 'dsh-plugin-chatgpt-siwc'));
  await patchTeams(stage);
  await patchScheduleAdmission(join(stage, 'node_modules', '@deepseek-ai', 'dsh-schedule', 'lib', 'index.js'));
  await patchSessionController(join(stage, 'node_modules', '@deepseek-ai', 'dsh-api-session-controller', 'lib', 'index.js'));
  await patchSessionPersistence(join(stage, 'node_modules', '@deepseek-ai', 'dsh-session-persistence-jsonl', 'lib', 'index.js'));
  await patchSessionQuery(join(stage, 'node_modules', '@deepseek-ai', 'dsh-session-query', 'lib', 'index.js'));
  await patchContextCompaction(join(stage, 'node_modules', '@deepseek-ai', 'dsh-compaction-basic', 'lib', 'index.js'));
  await patchContextAgentLoop(join(stage, 'node_modules', '@deepseek-ai', 'dsh-agent-loop', 'lib', 'index.js'));
  const upstreamPlatform = platform === 'windows' ? 'win' : platform;
  const archiveName = `node-v${version}-${upstreamPlatform}-${architecture}.${platform === 'windows' ? 'zip' : 'tar.gz'}`;
  const archive = join(temporary, archiveName);
  const response = await fetch(`https://nodejs.org/dist/v${version}/${archiveName}`);
  if (!response.ok || !response.body) throw new Error(`Node download failed: HTTP ${response.status}`);
  await pipeline(Readable.fromWeb(response.body), createWriteStream(archive));
  if (await digest(archive) !== expected) throw new Error('Node archive checksum mismatch');
  await command('tar', ['-xf', archive, '-C', temporary], temporary);
  const nodeSource = join(temporary, `node-v${version}-${upstreamPlatform}-${architecture}`);
  const nodePath = platform === 'windows' ? 'node/node.exe' : 'node/bin/node';
  await mkdir(dirname(join(stage, nodePath)), { recursive: true });
  await cp(join(nodeSource, platform === 'windows' ? 'node.exe' : 'bin/node'), join(stage, nodePath));
  await mkdir(join(stage, 'licenses', 'node'), { recursive: true });
  await mkdir(join(stage, 'licenses', 'pnpm'), { recursive: true });
  await cp(join(nodeSource, 'LICENSE'), join(stage, 'licenses', 'node', 'LICENSE'));
  await cp(join(stage, 'node_modules', 'pnpm', 'LICENSE'), join(stage, 'licenses', 'pnpm', 'LICENSE'));
  if (platform === 'windows') {
    const modules = join(stage, 'node_modules');
    const flattened = join(temporary, 'flat-modules');
    await cp(modules, flattened, { recursive: true, dereference: true });
    await rm(modules, { recursive: true });
    await rename(flattened, modules);
  }
  const buildPlatform = process.platform === 'win32' ? 'windows' : process.platform;
  if (platform === buildPlatform && architecture === process.arch) {
    await command(join(stage, nodePath), [join(stage, 'node_modules', 'pnpm', 'bin', 'pnpm.cjs'), '--version'], stage);
    const ptyCheck = `
      const pty = require('node-pty');
      const windows = process.platform === 'win32';
      const options = { cols: 80, rows: 24 };
      if (windows) options.useConptyDll = true;
      console.log('DSH_PTY_START');
      const terminal = pty.spawn(windows ? 'cmd.exe' : '/bin/sh',
        windows ? ['/d', '/s', '/c', 'echo DSH_RUNTIME_OK'] : ['-c', 'printf DSH_RUNTIME_OK'], options);
      console.log('DSH_PTY_SPAWNED');
      let output = '';
      let timedOut = false;
      const finish = code => process.stdout.write('', () => process.exit(code));
      const timer = setTimeout(() => {
        timedOut = true;
        console.log('DSH_PTY_TIMEOUT');
        try {
          terminal.kill();
        } finally {
          finish(1);
        }
      }, 20000);
      terminal.onData(chunk => { output += chunk; });
      terminal.onExit(({ exitCode }) => {
        clearTimeout(timer);
        const markerFound = output.includes('DSH_RUNTIME_OK');
        console.log('DSH_PTY_EXIT', JSON.stringify({ exitCode, markerFound }));
        finish(!timedOut && exitCode === 0 && markerFound ? 0 : 1);
      });
    `;
    await command(join(stage, nodePath), ['-e', ptyCheck], stage);
  }
  const manifest = {
    protocolVersion: 1, dshVersion: '0.2.2-rc.1',
    dshCommit: '66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db', node: nodePath,
    entry: 'host/index.mjs', platform, architecture, files: [], links: []
  };
  await inventory(stage, stage, manifest);
  await writeFile(join(stage, 'runtime.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  await mkdir(dirname(destination), { recursive: true });
  await cp(stage, destination, { recursive: true, errorOnExist: true, force: false, verbatimSymlinks: true });
  process.stdout.write(`Built embedded DSH runtime: ${destination}\n`);
} finally { await rm(temporary, { recursive: true, force: true }); }

function command(executable, argv, cwd) {
  return new Promise((accept, reject) => {
    const env = { ...process.env, PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? ''}` };
    const child = spawn(executable, argv, { cwd, env, stdio: 'inherit', shell: process.platform === 'win32' && executable.endsWith('.cmd') });
    child.once('error', reject);
    child.once('exit', code => code === 0 ? accept() : reject(new Error(`${basename(executable)} exited ${code}`)));
  });
}
async function digest(path) {
  const hash = createHash('sha256');
  for await (const data of createReadStream(path)) hash.update(data);
  return hash.digest('hex');
}
async function patchIdentity(path) {
  const text = await readFile(path, 'utf8');
  const old = "url.searchParams.set('agent_name_hint', 'DSH ChatGPT SIWC');";
  if (text.split(old).length !== 2) throw new Error('SIWC identity patch does not match pinned source');
  await writeFile(path, text.replace(old, "url.searchParams.set('agent_name_hint', 'Codex Bridge');"));
}
async function patchTeams(stage) {
  const modules = join(stage, 'node_modules', '@deepseek-ai');
  const toolPath = join(modules, 'dsh-experimental-tool-agent-team', 'lib', 'index.js');
  let tools = await readFile(toolPath, 'utf8');
  for (const name of ['send_message', 'list_agents', 'interrupt_agent']) {
    if (tools.split(`name: "${name}"`).length !== 2) throw new Error(`Teams tool patch does not match pinned source: ${name}`);
    tools = tools.replaceAll(name, `team_${name}`);
  }
  await writeFile(toolPath, tools);
  const profilePath = join(modules, 'dsh-experimental-agent-team-profile', 'cordis.patch.yml');
  let profile = await readFile(profilePath, 'utf8');
  for (const id of ['tool-subagent-control', 'tool-subagent', 'tool-subagent-fork']) {
    const disabled = `- id: ${id}\n  disabled: true\n`;
    if (profile.split(disabled).length !== 2) throw new Error(`Teams profile patch does not match pinned source: ${id}`);
    profile = profile.replace(disabled, '');
  }
  await writeFile(profilePath, profile);
}
async function inventory(rootPath, dir, manifest) {
  const canonicalRoot = await realpath(rootPath);
  for (const entry of (await readdir(dir)).sort()) {
    const path = join(dir, entry);
    const name = relative(rootPath, path).split(sep).join('/');
    const info = await lstat(path);
    if (info.isDirectory()) await inventory(rootPath, path, manifest);
    else if (info.isFile()) manifest.files.push({ path: name, sha256: await digest(path) });
    else if (info.isSymbolicLink()) {
      const target = await readlink(path);
      const resolved = await realpath(path);
      if (isAbsolute(target) || relative(canonicalRoot, resolved).startsWith('..')) throw new Error(`Invalid runtime link: ${name}`);
      manifest.links.push({ path: name, target });
    } else throw new Error(`Unsupported runtime entry: ${name}`);
  }
}
