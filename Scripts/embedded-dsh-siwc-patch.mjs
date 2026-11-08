import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const quotaMessageBefore = String.raw`\u6062\u590D\u540E\u5237\u65B0\u6A21\u578B\u3002`;
const quotaMessageAfter = String.raw`\u6062\u590D\u540E\u7EE7\u7EED\u5BF9\u8BDD\u3002`;

const patches = [
  {
    path: 'lib/api/controller.js',
    sha256: '1efe2df983bcb41b3db1fce23246d5d7ed12e84375043507c8d77b4fb15d2247',
    replacements: [
      [
        '            onUsage: (usage, connection) => this.recordUsage(usage, connection),\n',
        '            onUsage: (usage, connection) => this.recordUsage(usage, connection),\n' +
        '            onSuccess: connection => {\n' +
        '                if (connection.signal?.aborted) return;\n' +
        "                this.availability = 'ready';\n" +
        '                this.error = undefined;\n' +
        '            },\n'
      ],
      [
        "        if (this.availability === 'usage-limited') {\n" +
        "            throw new LlmError('ChatGPT 计划用量已达上限，请管理用量后刷新模型。', 'QUOTA');\n" +
        '        }\n',
        ''
      ]
    ]
  },
  {
    path: 'lib/provider/adapter.js',
    sha256: '14cd80d49a8c7ce425d4e8cca53be63b139ec9c167a33c5671a19fd1993eb794',
    replacements: [[
      "                                    await this.dependencies.onCapability?.(options.model, cap, 'supported', connection);\n" +
      '                            }\n                        }\n                        else {',
      "                                    await this.dependencies.onCapability?.(options.model, cap, 'supported', connection);\n" +
      '                            }\n' +
      '                            this.dependencies.onSuccess?.(connection);\n' +
      '                        }\n                        else {'
    ]]
  },
  {
    path: 'lib/client/Settings.js',
    sha256: 'fede1e2b6e9dfce098fda3d977d410e7f20c28616c6a5e4b253b7684ff88e342',
    replacements: [[quotaMessageBefore, quotaMessageAfter]]
  },
  {
    path: 'lib/client.js',
    sha256: 'e7f013e88207ac73a5286ffa9b7716766e66c32b2a72323453b00d98e7033e6e',
    replacements: [[quotaMessageBefore, quotaMessageAfter]]
  }
];

// Backport upstream a7922c8 to the published 0.9.7 runtime until the fix is released.
export async function patchSiwc(packageRoot) {
  const results = await Promise.all(patches.map(async ({ path, sha256, replacements }) => {
    const filename = join(packageRoot, path);
    let source = await readFile(filename, 'utf8');
    if (createHash('sha256').update(source).digest('hex') !== sha256) {
      throw new Error(`ChatGPT SIWC ${path} does not match the pinned runtime`);
    }
    for (const [before, after] of replacements) {
      if (source.split(before).length !== 2) {
        throw new Error(`ChatGPT SIWC patch does not match ${path}`);
      }
      source = source.replace(before, after);
    }
    return { filename, source };
  }));
  for (const { filename, source } of results) await writeFile(filename, source);
}
