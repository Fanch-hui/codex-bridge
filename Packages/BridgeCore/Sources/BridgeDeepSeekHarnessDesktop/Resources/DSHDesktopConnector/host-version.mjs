import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fault } from './errors.mjs';

export async function hostVersion(installAnchor) {
  if (typeof installAnchor !== 'string' || !path.isAbsolute(installAnchor) || path.basename(installAnchor) !== 'package.json') throw fault('native_desktop_version_unavailable', 'Desktop Host installation metadata is unavailable');
  let metadata;
  try { metadata = JSON.parse(await readFile(installAnchor, 'utf8')); }
  catch { throw fault('native_desktop_version_unavailable', 'Desktop Host installation metadata could not be read'); }
  if (!['@deepseek-ai/dsh-desktop-host', '@deepseek-ai/dsh'].includes(metadata.name) || typeof metadata.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(metadata.version)) throw fault('native_desktop_version_unavailable', 'Official Desktop Host version is missing from its installation metadata');
  return metadata.version;
}
