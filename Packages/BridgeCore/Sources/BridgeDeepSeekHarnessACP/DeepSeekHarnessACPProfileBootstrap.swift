import Foundation

enum DeepSeekHarnessACPProfileBootstrap {
  static func prepare(
    configurationDirectory: String, runDirectory: String, usesMessagesProvider: Bool = false
  ) throws -> String {
    let source = URL(fileURLWithPath: configurationDirectory).appendingPathComponent(".env").path
    let literal = String(data: try JSONEncoder().encode(source), encoding: .utf8)!
    let keys =
      ["DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DEEPSEEK_SEARCH_BASE_URL"]
      + DeepSeekHarnessACPProxyEnvironment.keys
    let names = String(data: try JSONEncoder().encode(keys), encoding: .utf8)!
    let script = """
      import { readFileSync } from 'node:fs';
      import { parseEnv } from 'node:util';
      let values = {};
      try {
        values = parseEnv(readFileSync(\(literal), 'utf8'));
      } catch (error) {
        if (error.code !== 'ENOENT') throw new Error('DSH profile environment is unreadable.');
      }
      const inheritedProxies = new Set(Object.keys(process.env)
        .filter(name => /^(https?|all|no)_proxy$/i.test(name)).map(name => name.toLowerCase()));
      for (const name of \(names)) {
        if (inheritedProxies.has(name.toLowerCase())) continue;
        if (process.env[name] === undefined && values[name] !== undefined) {
          process.env[name] = values[name];
        }
      }
      if (!\(usesMessagesProvider ? "true" : "false") && process.env.DEEPSEEK_SEARCH_BASE_URL === undefined && process.env.DEEPSEEK_BASE_URL) {
        process.env.DEEPSEEK_SEARCH_BASE_URL = process.env.DEEPSEEK_BASE_URL;
      }
      if (\(usesMessagesProvider ? "true" : "false") && process.env.BRIDGE_DSH_PROTOCOL !== 'openai-completions') {
        const base = process.env.DEEPSEEK_BASE_URL;
        const url = base ? new URL(base) : null;
        if (url && url.hostname === 'api.deepseek.com' && ['', '/', '/v1', '/v1/'].includes(url.pathname)) {
          process.env.DEEPSEEK_BASE_URL = 'https://api.deepseek.com/anthropic';
        }
      }
      """
    let path = URL(fileURLWithPath: runDirectory).appendingPathComponent("profile-env.mjs")
    try Data(script.utf8).write(to: path, options: .atomic)
    return path.absoluteString
  }
}
