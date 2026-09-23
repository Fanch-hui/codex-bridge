import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

const TOKEN_HEADER = 'X-Codex-Bridge-Token';
const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);

class ConfigurationError extends Error {}

function configuredEndpoint() {
  const value = process.env.CODEX_BRIDGE_MCP_URL?.trim();
  if (!value) {
    throw new ConfigurationError(
      'Codex Bridge MCP endpoint is not configured. Copy the current Qwen Studio endpoint from Bridge Connections.'
    );
  }

  let endpoint;
  try {
    endpoint = new URL(value);
  } catch {
    throw new ConfigurationError('Codex Bridge MCP endpoint is not a valid URL.');
  }

  const host = endpoint.hostname.toLowerCase();
  if (!LOOPBACK_HOSTS.has(host)) {
    throw new ConfigurationError('Codex Bridge MCP endpoint must use a loopback host.');
  }
  if (endpoint.protocol !== 'http:' && endpoint.protocol !== 'https:') {
    throw new ConfigurationError('Codex Bridge MCP endpoint must use HTTP or HTTPS.');
  }
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new ConfigurationError('Codex Bridge MCP endpoint must not contain credentials or query data.');
  }
  if (endpoint.pathname !== '/mcp') {
    throw new ConfigurationError('Codex Bridge MCP endpoint must use the /mcp path.');
  }
  return endpoint;
}

function configuredToken() {
  const token = process.env.CODEX_BRIDGE_MCP_TOKEN;
  if (!token || /[\r\n]/u.test(token)) {
    throw new ConfigurationError(
      'Codex Bridge MCP token is not configured. Copy the current Qwen Studio token from Bridge Connections.'
    );
  }
  return token;
}

function errorCode(error) {
  return error && typeof error === 'object' && 'code' in error
    ? Number(error.code)
    : undefined;
}

function errorMessage(error) {
  const code = errorCode(error);
  if (code === 401) {
    return 'Codex Bridge rejected the configured MCP token (HTTP 401). Copy a current Qwen Studio token from Bridge Connections.';
  }
  if (code >= 400 && code < 600) {
    return `Codex Bridge MCP request failed (HTTP ${code}).`;
  }
  if (error instanceof ConfigurationError) return error.message;
  return 'Codex Bridge MCP connection failed. Confirm that Bridge is running and the Qwen Studio MCP configuration is current.';
}

function startProxy(endpoint, token) {
  const stdio = new StdioServerTransport();
  const upstream = new StreamableHTTPClientTransport(endpoint, {
    requestInit: {
      redirect: 'error',
      headers: {
        [TOKEN_HEADER]: token,
      },
    },
    reconnectionOptions: {
      initialReconnectionDelay: 250,
      maxReconnectionDelay: 1_000,
      reconnectionDelayGrowFactor: 2,
      maxRetries: 0,
    },
  });

  let closed = false;
  let failureReported = false;
  let shutdownPromise;
  let initializeRequestID;
  let initializeRequestSeen = false;
  let initializeForwarding;

  const reportFailure = error => {
    process.exitCode = 1;
    if (!failureReported) {
      failureReported = true;
      process.stderr.write(`${errorMessage(error)}\n`);
    }
    void shutdown();
  };

  const forwardToUpstream = async message => {
    if (closed) return;
    if (message?.method === 'initialize' && !initializeRequestSeen) {
      initializeRequestSeen = true;
      initializeRequestID = message.id;
      initializeForwarding = upstream.send(message);
      await initializeForwarding;
      return;
    }
    if (initializeForwarding) await initializeForwarding;
    await upstream.send(message);
  };

  stdio.onmessage = message => {
    void forwardToUpstream(message).catch(reportFailure);
  };

  upstream.onmessage = message => {
    if (
      initializeRequestSeen &&
      message?.id === initializeRequestID &&
      typeof message?.result?.protocolVersion === 'string'
    ) {
      upstream.setProtocolVersion?.(message.result.protocolVersion);
    }
    void stdio.send(message).catch(reportFailure);
  };

  stdio.onerror = reportFailure;
  upstream.onerror = reportFailure;
  stdio.onclose = () => void shutdown();
  upstream.onclose = () => void shutdown();

  async function shutdown() {
    if (shutdownPromise) return shutdownPromise;
    closed = true;
    shutdownPromise = (async () => {
      try {
        await upstream.terminateSession();
      } catch {
        // The session may already be gone while the process is shutting down.
      }
      await upstream.close();
      await stdio.close();
    })();
    return shutdownPromise;
  }

  process.once('SIGINT', () => void shutdown());
  process.once('SIGTERM', () => void shutdown());
  process.stdin.once('end', () => void shutdown());
  process.stdout.once('error', error => reportFailure(error));

  return async () => {
    await upstream.start();
    await stdio.start();
  };
}

async function main() {
  const endpoint = configuredEndpoint();
  const token = configuredToken();
  await startProxy(endpoint, token)();
}

try {
  await main();
} catch (error) {
  process.stderr.write(`${errorMessage(error)}\n`);
  process.exitCode = 1;
}
