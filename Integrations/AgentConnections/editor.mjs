import { parse as parseTOML, patch as patchTOML } from '@decimalturn/toml-patch';
import { applyEdits, modify, parseTree } from 'jsonc-parser';
import { isDeepStrictEqual } from 'node:util';

function jsonDocument(source, strict) {
  const errors = [];
  const tree = parseTree(source, errors, {
    allowTrailingComma: !strict,
    disallowComments: strict,
  });
  if (errors.length || tree?.type !== 'object') throw new Error('invalid_configuration');
  return tree;
}

function jsonValue(tree, path) {
  let node = tree;
  for (const key of path) {
    if (!node) return { exists: false };
    if (node.type !== 'object') throw new Error('invalid_configuration');
    const properties = node.children.filter(property => property.children?.[0]?.value === key);
    if (properties.length > 1) throw new Error('duplicate_configuration_key');
    node = properties[0]?.children?.[1];
  }
  if (!node) return { exists: false };
  return { exists: true, value: valueOf(node) };
}

function valueOf(node) {
  if (node.type === 'object') {
    const value = Object.create(null);
    for (const property of node.children ?? []) {
      const key = property.children[0].value;
      if (Object.hasOwn(value, key)) throw new Error('duplicate_configuration_key');
      Object.defineProperty(value, key, { value: valueOf(property.children[1]), enumerable: true });
    }
    return value;
  }
  if (node.type === 'array') return (node.children ?? []).map(valueOf);
  return node.value;
}

function tomlValue(object, path) {
  let value = object;
  for (const key of path) {
    if (!value || typeof value !== 'object' || Array.isArray(value) || value instanceof Date) {
      throw new Error('invalid_configuration');
    }
    if (!Object.hasOwn(value, key)) return { exists: false };
    value = value[key];
  }
  return { exists: true, value };
}

function tomlSet(object, path, state) {
  let value = object;
  const parents = [];
  for (const key of path.slice(0, -1)) {
    parents.push(value);
    if (!Object.hasOwn(value, key)) value[key] = {};
    value = value[key];
    if (!value || typeof value !== 'object' || Array.isArray(value) || value instanceof Date) {
      throw new Error('invalid_configuration');
    }
  }
  const key = path.at(-1);
  if (state.exists) {
    value[key] = state.value;
    return;
  }
  delete value[key];
  // A removed entry takes along the tables it leaves empty, such as `[model_providers]`.
  for (let depth = parents.length - 1; depth >= 0 && Object.keys(value).length === 0; depth -= 1) {
    delete parents[depth][path[depth]];
    value = parents[depth];
  }
}

export function inspect(source, format, path) {
  if (format === 'toml') return tomlValue(parseTOML(source), path);
  return jsonValue(jsonDocument(source, format === 'json'), path);
}

export function edit(source, format, changes) {
  if (format === 'toml') {
    const document = parseTOML(source);
    for (const change of changes) tomlSet(document, change.path, change.after);
    return patchTOML(source, document);
  }
  let output = source;
  for (const change of changes) {
    jsonValue(jsonDocument(output, format === 'json'), change.path);
    const formattingOptions = { insertSpaces: true, tabSize: 2, eol: output.includes('\r\n') ? '\r\n' : '\n' };
    output = applyEdits(output, modify(output, change.path,
      change.after.exists ? change.after.value : undefined, { formattingOptions }));
  }
  jsonDocument(output, format === 'json');
  return output;
}

// With keepDrifted, fields another writer changed since Bridge applied them stay as they are
// (reported in `kept`) instead of blocking the whole revert.
// A change with `reclaimPrefix` never set its field; it restores `before` only while the field
// holds a string with that prefix, and is otherwise left alone without counting as drift.
export function reverse(source, format, changes, { keepDrifted = false } = {}) {
  const current = change => normalise(inspect(source, format, change.path));
  const reclaimed = changes.filter(change => change.reclaimPrefix !== undefined);
  const tracked = changes.filter(change => change.reclaimPrefix === undefined);
  const drifted = tracked.filter(change => !isDeepStrictEqual(current(change), normalise(change.after)));
  if (drifted.length && !keepDrifted) return { conflicts: drifted.map(change => change.path) };
  const owned = tracked.filter(change => !drifted.includes(change)).concat(reclaimed.filter(change => {
    const state = current(change);
    return typeof change.reclaimPrefix === 'string' && state.exists && typeof state.value === 'string' &&
      state.value.startsWith(change.reclaimPrefix);
  }));
  const content = edit(source, format, owned.map(change => ({ path: change.path, after: change.before })));
  return keepDrifted ? { content, kept: drifted.map(change => change.path) } : { content };
}

function normalise(value) {
  return JSON.parse(JSON.stringify(value));
}
