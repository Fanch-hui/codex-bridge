import { readFile, writeFile } from 'node:fs/promises';

export async function patchGatewayPiAi(path) {
  let source = await readFile(path, 'utf8');
  const stream = '\t\t\t\tconst iterator = toStreamChunks(snapshot.models.streamSimple(model, context, {\n';
  if (source.split(stream).length !== 2) throw new Error('DSH pi-ai stream patch does not match the pinned runtime');
  source = source.replace(stream,
    '\t\t\t\tconst gatewayUsage = options.bridgeExternal ? { input: false, output: false } : undefined;\n' +
    '\t\t\t\tconst recordUsage = gatewayUsage ? (await import("../../../../host/gateway-provider-options.mjs")).recordGatewayUsage : undefined;\n' + stream);
  const before = '\t\t\t\t\t...options.sessionId === void 0 ? {} : { sessionId: String(options.sessionId) },\n';
  const after = before +
    '\t\t\t\t\t...gatewayUsage === void 0 ? {} : { onProviderStreamEvent: (event, model) => recordUsage(gatewayUsage, event, model.api) },\n' +
    '\t\t\t\t\t...options.bridgeGateway === void 0 ? {} : {\n' +
    '\t\t\t\t\t\tmaxRetries: 0,\n' +
    '\t\t\t\t\t\tonPayload: async (payload, model) => {\n' +
    '\t\t\t\t\t\t\tconst { projectGatewayOptions } = await import("../../../../host/gateway-provider-options.mjs");\n' +
    '\t\t\t\t\t\t\treturn projectGatewayOptions(payload, model, options.bridgeGateway);\n' +
    '\t\t\t\t\t\t}\n' +
    '\t\t\t\t\t},\n';
  if (source.split(before).length !== 2) throw new Error('DSH pi-ai gateway patch does not match the pinned runtime');
  source = source.replace(before, after);
  const next = '\t\t\t\t\t\tconst result = await watchdog.next(iterator);\n';
  if (source.split(next).length !== 2) throw new Error('DSH pi-ai usage patch does not match the pinned runtime');
  source = source.replace(next, next +
    '\t\t\t\t\t\tif (gatewayUsage && result.value?.type === "usage" && (!gatewayUsage.input || !gatewayUsage.output)) continue;\n');
  await writeFile(path, source);
}

export async function patchGatewaySiwc(path) {
  const source = await readFile(path, 'utf8');
  const before = '    if (options.system)\n        body.instructions = options.system;\n';
  const after = before +
    '    if (options.bridgeGateway) {\n' +
    '        const { projectSiwcGatewayOptions } = await import("../../../../host/gateway-provider-options.mjs");\n' +
    '        Object.assign(body, projectSiwcGatewayOptions(body, identities, options.bridgeGateway));\n' +
    '    }\n';
  if (source.split(before).length !== 2) throw new Error('SIWC gateway patch does not match the pinned runtime');
  await writeFile(path, source.replace(before, after));
}

export async function patchGatewayZcode(path) {
  const source = await readFile(path, 'utf8');
  const before = '            const body = await buildRequest({ ...options, messages, signal }, context, this.dependencies.image);\n';
  const after = before +
    '            if (options.bridgeGateway) {\n' +
    '                const { projectGatewayOptions } = await import("../../../../host/gateway-provider-options.mjs");\n' +
    '                Object.assign(body, projectGatewayOptions(body, { api: "anthropic-messages" }, options.bridgeGateway));\n' +
    '            }\n';
  if (source.split(before).length !== 2) throw new Error('ZCode gateway patch does not match the pinned runtime');
  await writeFile(path, source.replace(before, after));
}
