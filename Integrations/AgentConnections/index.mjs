import { prepare, revert } from './connections.mjs';

try {
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk;
    if (Buffer.byteLength(input) > 4 * 1024 * 1024) throw new Error('input_too_large');
  }
  const request = JSON.parse(input);
  const result = request.operation === 'prepare' ? prepare(request)
    : request.operation === 'revert' ? revert(request) : undefined;
  if (!result) throw new Error('unsupported_operation');
  process.stdout.write(JSON.stringify({ result }));
} catch (error) {
  const code = /^[a-z_]+$/.test(error.message) ? error.message : 'configuration_edit_failed';
  process.stdout.write(JSON.stringify({ error: code }));
  process.exitCode = 1;
}
