function containsSecret(schema, id, path, value, depth = 0) {
  if (depth > 80) throw new Error('设置结构过深。');
  const node = schema.refs?.[id];
  if (!node) return false;
  if (node.meta?.role === 'secret') {
    return value !== undefined && value !== null && value !== ''
      && (typeof value !== 'object' || Object.keys(value).length > 0);
  }
  const visit = (child, nextPath, nextValue) => containsSecret(schema, child, nextPath, nextValue, depth + 1);
  if (node.type === 'union' || node.type === 'intersect') return (node.list ?? []).some(child => visit(child, path, value));
  if (node.type === 'transform') return visit(node.inner, path, value);
  if (path.length) {
    const [head, ...tail] = path;
    if (node.type === 'object') return visit(node.dict?.[head], tail, value);
    if (node.type === 'dict' || node.type === 'array') return visit(node.inner, tail, value);
    return false;
  }
  if (!value || typeof value !== 'object') return false;
  if (node.type === 'object') return Object.entries(value).some(([key, item]) => visit(node.dict?.[key], [], item));
  if (node.type === 'dict' || node.type === 'array') return Object.values(value).some(item => visit(node.inner, [], item));
  return false;
}

export function validateSettingsWrite(controller, endpoint, args) {
  if (!['settings/mutate', 'settings/update', 'settings/replace'].includes(endpoint)) return;
  const descriptor = controller.describe().namespaces.find(item => item.ns === args.ns);
  if (!descriptor?.schema) throw new Error('设置项不可用。');
  const changes = endpoint === 'settings/mutate' ? args.ops : [{ path: [], value: args[endpoint === 'settings/update' ? 'patch' : 'section'] }];
  if (!Array.isArray(changes)) throw new Error('设置变更无效。');
  for (const change of changes) {
    if (!Array.isArray(change.path) || change.path.some(key => typeof key !== 'string')) throw new Error('设置路径无效。');
    if (args.ns === 'llm-pi-ai' && (endpoint === 'settings/replace' || change.path[0] === 'providers'
      || change.path.length === 0 && (change.op === 'unset' || Object.hasOwn(change.value ?? {}, 'providers')))) {
      throw new Error('请在模型连接中管理模型服务。');
    }
    if (change.op === 'unset') continue;
    if (containsSecret(descriptor.schema, descriptor.schema.uid, change.path, change.value)) {
      throw new Error('请通过凭据输入框保存密钥。');
    }
  }
}
