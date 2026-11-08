import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { parse } from 'yaml';

const require = createRequire(import.meta.url);
const upstream = dirname(require.resolve('@deepseek-ai/dsh-web-app/package.json'));
const jsTag = { tag: 'tag:yaml.org,2002:js', resolve: value => value };
const excluded = new Set(['client-hmr', 'ui-settings-models', 'ui-settings-account', 'ui-agent-preset']);

export function clientRoster() {
  const patch = parse(readFileSync(join(upstream, 'cordis.patch.yml'), 'utf8'), { customTags: [jsTag] });
  return patch.flatMap(row => row.insert ?? []).filter(row => {
    if (row.disabled || excluded.has(row.id) || !row.name) return false;
    let path;
    try { path = require.resolve(`${row.name}/package.json`); }
    catch (error) {
      if (error.code === 'MODULE_NOT_FOUND' || error.code === 'ERR_PACKAGE_PATH_NOT_EXPORTED') return false;
      throw error;
    }
    const pkg = JSON.parse(readFileSync(path, 'utf8'));
    return pkg.dsh?.client?.platform === 'web';
  }).map(row => ({ id: row.id, name: row.name }));
}
