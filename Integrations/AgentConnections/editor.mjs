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
  for (const key of path.slice(0, -1)) {
    if (!Object.hasOwn(value, key)) value[key] = {};
    value = value[key];
    if (!value || typeof value !== 'object' || Array.isArray(value) || value instanceof Date) {
      throw new Error('invalid_configuration');
    }
  }
  const key = path.at(-1);
  if (state.exists) value[key] = state.value;
  else delete value[key];
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

export function reverse(source, format, changes) {
  const conflicts = changes.filter(change => !isDeepStrictEqual(
    normalise(inspect(source, format, change.path)), normalise(change.after)));
  if (conflicts.length) return { conflicts: conflicts.map(change => change.path) };
  return { content: edit(source, format, changes.map(change => ({ path: change.path, after: change.before }))) };
}

function normalise(value) {
  return JSON.parse(JSON.stringify(value));
}
