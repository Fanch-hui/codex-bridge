import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { contained, requireValue, text } from './validation.mjs';

export async function stageSelectedSkills(skills) {
  if (skills.length === 0) return null;
  const root = await mkdtemp(path.join(os.tmpdir(), 'codex-bridge-qoder-skills-'));
  try {
    for (const skill of skills) await stageSkill(root, skill);
    return { root, additionalDirectories: [root], close: () => rm(root, { recursive: true, force: true }) };
  } catch (error) {
    await rm(root, { recursive: true, force: true });
    throw error;
  }
}

async function stageSkill(root, skill) {
  const skillRoot = path.join(root, '.agents', 'skills', directoryName(skill.name));
  for (const file of skill.files) {
    const parts = file.relativePath.split('/');
    requireValue(parts.length > 0 && parts.every(part => part && part !== '.' && part !== '..'
      && !part.includes('\\') && !part.includes(':')), 'invalid_skill_path');
    const destination = path.resolve(skillRoot, ...parts);
    requireValue(contained(skillRoot, destination), 'invalid_skill_path');
    await mkdir(path.dirname(destination), { recursive: true, mode: 0o700 });
    const content = file.relativePath === 'SKILL.md'
      ? setSkillName(file.content, skill.name) : file.content;
    await writeFile(destination, content, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
  }
}

function directoryName(name) {
  text(name, 128);
  return 'bridge-' + createHash('sha256').update(name).digest('hex').slice(0, 24);
}

function setSkillName(content, name) {
  text(content, 64 * 1024);
  const match = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/u.exec(content);
  if (!match) return `---\nname: ${JSON.stringify(name)}\ndescription: Bridge selected Skill\n---\n\n${content}`;
  const metadata = match[1].split(/\r?\n/u).filter(line => !/^name\s*:/iu.test(line));
  if (!metadata.some(line => /^description\s*:/iu.test(line))) metadata.push('description: Bridge selected Skill');
  const header = ['---', `name: ${JSON.stringify(name)}`, ...metadata, '---', ''].join('\n');
  return header + content.slice(match[0].length);
}
