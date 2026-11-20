import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createReadStream, createWriteStream } from 'node:fs';
import { chmod, mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const version = '1.4.2';
const targets = {
  'darwin-arm64': ['bun-darwin-aarch64', '90987a3a16d7db556d886ac3d551e7b6d3edf0a1cf43acaed622e8676be1d12f'],
  'darwin-x64': ['bun-darwin-x64', '80520d7e17526308c9185d261679ac6d27798d3803a0e9f7ff9121ab8affb012'],
  'linux-arm64': ['bun-linux-aarch64', '54328bbc2d9c8e0c9f892c544d66c57a83b84139e34909e5ee81758f1ac8fda7'],
  'linux-x64': ['bun-linux-x64-baseline', 'c678040f14fe0440eb839d37cbd0ce4c051a32da72806ac97de6a6aab6bf728f'],
  'win32-arm64': ['bun-windows-aarch64', 'a7a16b876a305fd1029c66dbd27007b4f6112ae896532f675878731a21e50cfd'],
  'win32-x64': ['bun-windows-x64-baseline', '78c221c2376f79731ccf4e4af0b3bb46d81fefa3296c5abee09ad8a1b21e68c6']
};

async function digest(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

export async function provisionBun(root) {
  if (!isAbsolute(root)) throw new Error('An absolute private runtime directory is required');
  const target = targets[`${process.platform}-${process.arch}`];
  if (!target) throw new Error('Bun is not available for this platform');
  const [archiveName, expected] = target;
  const parent = join(root, 'bun');
  const destination = join(parent, `${version}-${archiveName}`);
  const executableName = process.platform === 'win32' ? 'bun.exe' : 'bun';
  const executable = join(destination, executableName);
  try {
    const receipt = JSON.parse(await readFile(join(destination, 'receipt.json'), 'utf8'));
    if (receipt.version !== version || receipt.archive !== expected || receipt.binary !== await digest(executable)) {
      throw new Error('The installed Bun runtime changed');
    }
    return { path: executable, version };
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    try { await stat(destination); throw new Error('The installed Bun runtime is incomplete'); }
    catch (missing) { if (missing.code !== 'ENOENT') throw missing; }
  }
  await mkdir(parent, { recursive: true, mode: 0o700 });
  const staging = await mkdtemp(join(parent, '.bun-'));
  try {
    const archive = join(staging, 'bun.zip');
    const response = await fetch(`https://github.com/oven-sh/bun/releases/download/bun-v${version}/${archiveName}.zip`);
    if (!response.ok || !response.body) throw new Error(`Bun download failed: HTTP ${response.status}`);
    let size = 0;
    const bounded = new Transform({ transform(chunk, encoding, callback) {
      size += chunk.length;
      callback(size > 200 * 1024 * 1024 ? new Error('Bun archive is too large') : null, chunk);
    } });
    await pipeline(Readable.fromWeb(response.body), bounded, createWriteStream(archive, { mode: 0o600 }));
    if (await digest(archive) !== expected) throw new Error('Bun archive checksum does not match the official release');
    const binary = join(staging, executableName);
    await extract(archive, `${archiveName}/${executableName}`, binary);
    await chmod(binary, 0o700);
    const binaryDigest = await digest(binary);
    await rm(archive);
    await writeFile(join(staging, 'receipt.json'), JSON.stringify({ version, archive: expected, binary: binaryDigest }) + '\n', { mode: 0o600 });
    await rename(staging, destination);
    return { path: executable, version };
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

async function extract(archive, member, destination) {
  const child = spawn('tar', ['-xOf', archive, member], { stdio: ['ignore', 'pipe', 'ignore'] });
  const finished = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', code => code === 0 ? resolve() : reject(new Error('Bun archive extraction failed')));
  });
  await Promise.all([pipeline(child.stdout, createWriteStream(destination, { mode: 0o700 })), finished]);
}
