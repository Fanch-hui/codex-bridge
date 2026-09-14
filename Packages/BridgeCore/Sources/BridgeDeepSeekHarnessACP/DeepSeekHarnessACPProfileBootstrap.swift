import Foundation

enum DeepSeekHarnessACPProfileBootstrap {
  static func prepare(configurationDirectory: String, runDirectory: String) throws -> String {
    let source = URL(fileURLWithPath: configurationDirectory).appendingPathComponent(".env").path
    let literal = String(data: try JSONEncoder().encode(source), encoding: .utf8)!
    let script = """
      import { readFileSync } from 'node:fs';
      import { parseEnv } from 'node:util';
      let values = {};
      try {
        values = parseEnv(readFileSync(\(literal), 'utf8'));
      } catch (error) {
        if (error.code !== 'ENOENT') throw new Error('DSH profile environment is unreadable.');
      }
      for (const name of ['DEEPSEEK_API_KEY', 'DEEPSEEK_BASE_URL', 'DEEPSEEK_SEARCH_BASE_URL']) {
        if (process.env[name] === undefined && values[name] !== undefined) {
          process.env[name] = values[name];
        }
      }
      if (process.env.DEEPSEEK_SEARCH_BASE_URL === undefined && process.env.DEEPSEEK_BASE_URL) {
        process.env.DEEPSEEK_SEARCH_BASE_URL = process.env.DEEPSEEK_BASE_URL;
      }
      """
    let path = URL(fileURLWithPath: runDirectory).appendingPathComponent("profile-env.mjs")
    try Data(script.utf8).write(to: path, options: .atomic)
    return path.absoluteString
  }
}
