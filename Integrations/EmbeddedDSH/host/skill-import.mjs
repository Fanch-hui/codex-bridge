import { cp, lstat, mkdir, readFile, readdir, rename, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { basename, isAbsolute, join } from 'node:path';

// Imported skills land in the engine's user skill root (`<DSH_HOME>/skills`), which the
// filesystem skill provider watches, so they reach every session without a restart.
const maxFiles = 2000;
const maxBytes = 50 * 1024 * 1024;
const validName = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u;

function failure(message) { return Object.assign(new Error(message), { code: 'skill_import_invalid' }); }

// The provider drops a skill without `name` and `description` frontmatter, so reject it here
// with a reason the user can act on instead of importing something that never appears.
async function checkManifest(directory) {
  let text;
  try { text = await readFile(join(directory, 'SKILL.md'), 'utf8'); } catch { return false; }
  const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---/u.exec(text)?.[1];
  if (!frontmatter || !/^name:\s*\S/mu.test(frontmatter) || !/^description:\s*\S/mu.test(frontmatter)) {
    throw failure(`${basename(directory)}/SKILL.md 缺少 name 或 description`);
  }
  return true;
}

async function measure(directory, budget) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) continue; // Links are not copied, so they do not count.
    if (entry.isDirectory()) { await measure(path, budget); continue; }
    if (!entry.isFile()) continue;
    budget.files += 1;
    budget.bytes += (await lstat(path)).size;
    if (budget.files > maxFiles || budget.bytes > maxBytes) throw failure('技能文件过多或过大（上限 2000 个文件、50 MB）');
  }
}

// A folder with SKILL.md is one skill; otherwise each direct child folder with one is a skill.
async function sources(path) {
  if (await checkManifest(path)) return [path];
  const found = [];
  for (const entry of await readdir(path, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    if (await checkManifest(join(path, entry.name))) found.push(join(path, entry.name));
  }
  if (!found.length) throw failure('所选文件夹及其下一层都没有 SKILL.md');
  return found;
}

async function exists(path) {
  try { await lstat(path); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

// Copies into a staging folder first and swaps it in, so a failed copy never leaves a partial skill.
async function install(source, root) {
  const name = basename(source);
  if (!validName.test(name)) throw failure(`技能文件夹名「${name}」只能包含字母、数字、点、下划线和连字符`);
  const target = join(root, name);
  const staging = join(root, `.import-${randomUUID()}`);
  await cp(source, staging, { recursive: true, errorOnExist: true, force: false,
    filter: async path => !(await lstat(path)).isSymbolicLink() });
  const replaced = await exists(target);
  const previous = join(root, `.previous-${randomUUID()}`);
  try {
    if (replaced) await rename(target, previous);
    await rename(staging, target);
  } catch (error) {
    if (replaced && !(await exists(target))) await rename(previous, target);
    await rm(staging, { recursive: true, force: true });
    throw error;
  }
  if (replaced) await rm(previous, { recursive: true, force: true });
  return { name, replaced };
}

export async function importSkills({ path } = {}, home = process.env.DSH_HOME) {
  if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0')) throw failure('技能路径无效');
  if (!home) throw new Error('Workbench home is unavailable');
  if (!(await lstat(path)).isDirectory()) throw failure('请选择技能文件夹');
  const skills = await sources(path);
  const budget = { files: 0, bytes: 0 };
  for (const source of skills) await measure(source, budget);
  const root = join(home, 'skills');
  await mkdir(root, { recursive: true });
  const imported = [];
  for (const source of skills) imported.push(await install(source, root));
  return { imported };
}
