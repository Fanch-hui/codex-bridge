import { readFile, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import * as McpClient from '@deepseek-ai/dsh-mcp-client';

export class McpServers {
  constructor(ctx, rpc, home) {
    this.ctx = ctx;
    this.rpc = rpc;
    this.path = join(home, 'bridge-mcp.json');
    this.servers = [];
    this.fibers = new Map();
    this.queue = Promise.resolve();
  }
  async start() {
    try { this.servers = JSON.parse(await readFile(this.path, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    await Promise.all(this.servers.filter(server => server.enabled).map(server => this.mount(server)));
  }
  async mount(server) {
    const { value } = await this.rpc.request('bridge/secret', { operation: 'get', key: `mcp/${server.id}` });
    const serverName = `bridge-${createHash('sha256').update(server.id).digest('hex').slice(0, 20)}`;
    const config = { serverName, transport: server.transport,
      ...(server.transport === 'stdio' ? { command: server.command, args: server.args ?? [], env: value?.env ?? {} }
        : { url: value?.url ?? server.url, headers: value?.headers ?? {} }) };
    const fiber = await this.ctx.plugin(McpClient, config);
    this.fibers.set(server.id, fiber);
  }
  async unmount(id) {
    const fiber = this.fibers.get(id);
    if (fiber) { await fiber.dispose(); this.fibers.delete(id); }
  }
  list() { return { servers: this.servers.map(server => ({ ...server })) }; }
  async persist() {
    const temp = `${this.path}.tmp`;
    await writeFile(temp, `${JSON.stringify(this.servers, null, 2)}\n`, { mode: 0o600 });
    await rename(temp, this.path);
  }
  exclusive(fn) {
    const result = this.queue.then(fn, fn);
    this.queue = result.catch(() => {});
    return result;
  }
  save(input) {
    return this.exclusive(async () => {
      if (!/^[A-Za-z0-9_-]{1,100}$/.test(input.id ?? '')) throw new Error('Invalid MCP server ID');
      if (!['stdio', 'streamable-http'].includes(input.transport)) throw new Error('Invalid MCP transport');
      if (input.transport === 'stdio' && !input.command) throw new Error('MCP command is required');
      const previous = this.servers.find(x => x.id === input.id);
      const existingSecret = (await this.rpc.request('bridge/secret', { operation: 'get', key: `mcp/${input.id}` })).value ?? {};
      const secret = { ...existingSecret };
      if (input.env !== undefined) secret.env = input.env;
      if (input.headers !== undefined) secret.headers = input.headers;
      let publicURL;
      if (input.transport === 'streamable-http') {
        const url = new URL(input.url);
        if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Invalid MCP URL');
        const privateURL = !!(url.username || url.password || url.search || url.hash);
        url.username = ''; url.password = ''; url.search = ''; url.hash = '';
        publicURL = url.toString();
        if (privateURL) secret.url = input.url;
        else if (previous?.url !== publicURL) delete secret.url;
      } else delete secret.url;
      const hasCredentials = !!(Object.keys(secret.env ?? {}).length || Object.keys(secret.headers ?? {}).length || secret.url);
      const config = { id: input.id, name: input.name || input.id, transport: input.transport,
        enabled: input.enabled ?? previous?.enabled ?? true,
        hasCredentials,
        ...(input.transport === 'stdio' ? { command: input.command, args: input.args ?? [] } : { url: publicURL }) };
      await this.unmount(input.id);
      await this.rpc.request('bridge/secret', { operation: 'set', key: `mcp/${input.id}`, value: secret });
      this.servers = [...this.servers.filter(x => x.id !== input.id), config];
      await this.persist();
      if (config.enabled) await this.mount(config);
      return this.list();
    });
  }
  remove(id) {
    return this.exclusive(async () => {
      await this.unmount(id);
      this.servers = this.servers.filter(item => item.id !== id);
      await this.persist();
      await this.rpc.request('bridge/secret', { operation: 'delete', key: `mcp/${id}` });
      return this.list();
    });
  }
  setEnabled(id, enabled) {
    return this.exclusive(async () => {
      const server = this.servers.find(item => item.id === id);
      if (!server) throw new Error('MCP server not found');
      await this.unmount(id);
      server.enabled = enabled;
      await this.persist();
      if (enabled) await this.mount(server);
      return this.list();
    });
  }
}
