import { spawn } from 'node:child_process';
import { constants } from 'node:fs';
import { copyFile, mkdir, mkdtemp, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Directory holding catalog.json and bundled/, in the source tree and in the app's provider runtime alike.
const assetsDirectory = dirname(fileURLToPath(import.meta.url));
const bundledDirectory = /^[a-z0-9][a-z0-9-]{0,63}$/;
const packageName = /^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/;
const version = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

function run(bun, args, cwd, signal) {
  const env = { PATH: process.env.PATH, HOME: cwd, USERPROFILE: cwd, TMPDIR: cwd, TEMP: cwd, TMP: cwd };
  const byLower = new Map(Object.entries(process.env).map(([k, v]) => [k.toLowerCase(), v]));
  const systemRoot = byLower.get('systemroot') || byLower.get('windir');
  if (systemRoot) {
    env.SystemRoot = systemRoot;
    env.WINDIR = systemRoot;
  }
  for (const key of [
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
    'SSL_CERT_FILE', 'SSL_CERT_DIR', 'NODE_EXTRA_CA_CERTS'
  ]) {
    const value = process.env[key] ?? byLower.get(key.toLowerCase());
    if (value && !value.includes('\0')) env[key] = value;
  }
  return new Promise((resolve, reject) => {
    const child = spawn(bun, args, { cwd, env, stdio: ['ignore', 'ignore', 'pipe'], signal });
    let diagnostic = '';
    let processError;
    child.stderr.on('data', chunk => { diagnostic = (diagnostic + chunk).slice(-2048); });
    child.once('error', error => { processError = error; });
    child.once('close', (code, processSignal) => {
      if (processError) reject(processError);
      else if (code === 0) resolve();
      else reject(new Error(`Plugin installation failed (${processSignal ?? code}): ${diagnostic.replace(/\s+/g, ' ').trim()}`));
    });
  });
}

// Plugins shipped inside the app name their directory under bundled/ in the catalog.
async function bundledPackage(name, assets) {
  const catalog = JSON.parse(await readFile(join(assets, 'catalog.json'), 'utf8'));
  if (!Array.isArray(catalog.providers)) throw new Error('Plugin catalog is invalid');
  const entry = catalog.providers.find(provider => provider.package === name);
  if (entry?.bundled === undefined) return null;
  if (typeof entry.bundled !== 'string' || !bundledDirectory.test(entry.bundled) ||
      typeof entry.version !== 'string' || !version.test(entry.version)) {
    throw new Error('Bundled plugin catalog entry is invalid');
  }
  return { version: entry.version, source: join(assets, 'bundled', entry.bundled) };
}

async function copyBundled(source, destination) {
  await mkdir(destination, { recursive: true });
  for (const entry of await readdir(source, { withFileTypes: true })) {
    const from = join(source, entry.name);
    const to = join(destination, entry.name);
    if (entry.isDirectory()) await copyBundled(from, to);
    else if (entry.isFile()) await copyFile(from, to, constants.COPYFILE_EXCL);
    else throw new Error(`Bundled plugin contains an unsupported entry: ${entry.name}`);
  }
}

async function resolveBun(bun) {
  const path = typeof bun === 'function' ? await bun() : bun;
  if (typeof path !== 'string' || !isAbsolute(path)) throw new Error('Absolute Bun and installation paths are required');
  return path;
}

// `bun` is an absolute path or a function returning one; it is only called when the package comes from npm.
export async function installProvider({ bun, root, name, version: release, signal, assets = assetsDirectory }) {
  if (!isAbsolute(root) || (typeof bun === 'string' && !isAbsolute(bun))) {
    throw new Error('Absolute Bun and installation paths are required');
  }
  if (!packageName.test(name) || !version.test(release)) throw new Error('An npm package and exact version are required');
  const bundled = await bundledPackage(name, assets);
  if (bundled && bundled.version !== release) throw new Error('Only the plugin version shipped with the app can be installed');
  await mkdir(root, { recursive: true, mode: 0o700 });
  const packagePath = join('node_modules', ...name.split('/'));
  const parent = join(root, 'packages', encodeURIComponent(name));
  const destination = join(parent, release);
  try {
    const existing = JSON.parse(await readFile(join(destination, packagePath, 'package.json'), 'utf8'));
    if (existing.name !== name || existing.version !== release) throw new Error('Installed package identity does not match the requested version');
    return { spec: `${name}@${release}`, target: join(destination, packagePath), license: existing.license ?? null };
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  const staging = await mkdtemp(join(root, '.install-'));
  let moved = false;
  try {
    await writeFile(join(staging, 'package.json'), JSON.stringify({
      name: 'codex-bridge-community-provider', private: true, dependencies: { [name]: release }
    }) + '\n', { mode: 0o600 });
    if (bundled) await copyBundled(bundled.source, join(staging, packagePath));
    else await run(await resolveBun(bun), ['install', '--ignore-scripts', '--no-progress', '--registry', 'https://registry.npmjs.org'], staging, signal);
    const manifest = JSON.parse(await readFile(join(staging, packagePath, 'package.json'), 'utf8'));
    if (manifest.name !== name || manifest.version !== release) throw new Error('Installed package identity does not match the requested version');
    await mkdir(parent, { recursive: true });
    await rename(staging, destination);
    moved = true;
    return { spec: `${name}@${release}`, target: join(destination, packagePath), license: manifest.license ?? null };
  } finally {
    if (!moved) await rm(staging, { recursive: true, force: true });
  }
}

export async function removeProvider({ root, name }) {
  if (!isAbsolute(root) || !packageName.test(name)) throw new Error('An absolute installation path and npm package are required');
  await rm(join(root, 'packages', encodeURIComponent(name)), { recursive: true, force: true });
  return { removed: true };
}

export async function latestProviderVersion(name, { assets = assetsDirectory } = {}) {
  if (!packageName.test(name)) throw new Error('An npm package name is required');
  const bundled = await bundledPackage(name, assets);
  if (bundled) return { version: bundled.version };
  const response = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}/latest`, {
    headers: { accept: 'application/json' }, signal: AbortSignal.timeout(30000)
  });
  if (!response.ok || !response.body) throw new Error(`Plugin update check failed (${response.status})`);
  const chunks = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > 1024 * 1024) throw new Error('Plugin update information is too large');
    chunks.push(chunk);
  }
  const manifest = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (manifest.name !== name || typeof manifest.version !== 'string' || manifest.version.length > 128 ||
      !version.test(manifest.version)) {
    throw new Error('Plugin update information is invalid');
  }
  return { version: manifest.version };
}
