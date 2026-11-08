import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repository = fileURLToPath(new URL('../', import.meta.url));
const source = join(repository, 'Integrations/DSHConversationUI');
const staging = join(repository, '.build/dsh-conversation-ui');
const resources = join(repository, 'Packages/BridgeCore/Sources/BridgeDesktopUI/Resources');
const upstream = JSON.parse(await readFile(join(repository, 'Integrations/EmbeddedDSH/upstream.json'), 'utf8')).dsh;
const manifest = JSON.parse(await readFile(join(source, 'package.json'), 'utf8'));
if (manifest.dependencies['@deepseek-ai/dsh-client-ui-primitives'] !== upstream.version) {
  throw new Error('DSH conversation component version does not match the embedded engine.');
}

await mkdir(staging, { recursive: true });
for (const name of ['package.json', 'package-lock.json', 'entry.jsx']) await copyFile(join(source, name), join(staging, name));
const install = spawnSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', [
  'ci', '--ignore-scripts', '--no-audit', '--no-fund',
], { cwd: staging, stdio: 'inherit', shell: process.platform === 'win32' });
if (install.error) throw install.error;
if (install.status !== 0) throw new Error(`npm ci exited with ${install.status}.`);

const modules = join(staging, 'node_modules');
const esbuild = await import(pathToFileURL(join(modules, 'esbuild/lib/main.js')));
const result = await esbuild.build({
  absWorkingDir: repository,
  entryPoints: [join(staging, 'entry.jsx')],
  outfile: join(resources, 'dsh-conversation-upstream.js'),
  nodePaths: [modules],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'es2020',
  // Preserve whitespace in upstream literals with escaped string syntax.
  supported: { 'template-literal': false },
  minify: true,
  metafile: true,
  legalComments: 'none',
  define: { 'process.env.NODE_ENV': '"production"' },
  loader: { '.woff2': 'dataurl', '.woff': 'dataurl', '.ttf': 'dataurl', '.eot': 'dataurl' },
  banner: { js: `/* deepseek-harness ${upstream.version} (${upstream.commit}); licenses: dsh-conversation-licenses.txt */` },
});
const postcss = (await import(pathToFileURL(join(modules, 'postcss/lib/postcss.mjs')))).default;
const stylesheet = join(resources, 'dsh-conversation-upstream.css');
const css = postcss.parse(await readFile(stylesheet, 'utf8'));
const animations = new Map();
css.walkAtRules(/keyframes$/i, rule => {
  const name = rule.params;
  animations.set(name, `dsh-conversation-${name}`);
  rule.params = animations.get(name);
});
css.walkDecls(/^(?:-webkit-)?animation(?:-name)?$/, declaration => {
  declaration.value = declaration.value.replace(/[-_a-zA-Z][-_a-zA-Z0-9]*/g, name => animations.get(name) || name);
});
css.walkRules(rule => {
  if (rule.parent.type === 'atrule' && /keyframes$/i.test(rule.parent.name)) return;
  rule.selectors = rule.selectors.map(selector => `.dsh-upstream-entry ${selector}`);
});
await writeFile(stylesheet, css.toString());

const packages = new Map();
for (const output of Object.values(result.metafile.outputs)) {
  for (const input of Object.keys(output.inputs)) {
    let directory = dirname(resolve(repository, input));
    while (directory.startsWith(modules + sep)) {
      try {
        const pkg = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
        if (pkg.name) { packages.set(`${pkg.name}@${pkg.version}`, directory); break; }
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      directory = dirname(directory);
    }
  }
}
if (!packages.has(`@deepseek-ai/dsh-client-ui-primitives@${upstream.version}`)) {
  throw new Error('The bundled DSH component license was not located.');
}
const notices = [];
for (const [name, directory] of [...packages].sort(([a], [b]) => a.localeCompare(b))) {
  const files = (await readdir(directory)).filter(name => /^(license|copying|notice)(\.|$)/i.test(name)).sort();
  if (!files.length) throw new Error(`Missing license for bundled dependency ${name}.`);
  const texts = await Promise.all(files.map(file => readFile(join(directory, file), 'utf8')));
  notices.push(`${name}\n\n${texts.join('\n\n').trim()}`);
}
await writeFile(join(resources, 'dsh-conversation-licenses.txt'), notices.join('\n\n----------------------------------------\n\n') + '\n');
