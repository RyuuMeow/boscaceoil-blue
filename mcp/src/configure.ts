import { randomBytes } from 'node:crypto';
import { lstat, mkdir, open, realpath } from 'node:fs/promises';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const values = new Map<string, string>();
let valid = args.length % 2 === 0;
for (let i = 0; i < args.length; i += 2) {
  const key = args[i]!;
  const value = args[i + 1];
  if (!['--config', '--root', '--mode', '--port'].includes(key) || !value || values.has(key)) valid = false;
  else values.set(key, value);
}
const path = values.get('--config');
const root = values.get('--root');
const mode = values.get('--mode') ?? 'read_only';
const port = Number(values.get('--port') ?? '37641');
if (!valid || !path || !root || !isAbsolute(path) || !isAbsolute(root) || !['read_only', 'edit'].includes(mode) || !Number.isInteger(port) || port < 1024 || port > 65535) {
  process.stderr.write('Usage: node dist/configure.js --config <absolute file> --root <existing song directory> [--mode read_only|edit] [--port 37641]\n');
  process.exitCode = 1;
} else {
  try {
    const rootInfo = await lstat(root);
    if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) throw new Error('Select an existing, unlinked song directory.');
    const actualRoot = await realpath(root);
    await mkdir(dirname(path), { recursive: true });
    const file = await open(path, 'wx', 0o600);
    try {
      // Windows ignores POSIX mode bits. Protect the file before writing the token.
      if (process.platform === 'win32') {
        const identity = spawnSync('whoami.exe', [], { encoding: 'utf8', windowsHide: true });
        if (identity.status !== 0) throw new Error('Cannot determine the Windows account for file permissions.');
        const acl = spawnSync('icacls.exe', [resolve(path), '/inheritance:r', '/grant:r', `${identity.stdout.trim()}:(F)`], { windowsHide: true });
        if (acl.status !== 0) throw new Error('Cannot protect the MCP configuration file.');
      }
      await file.writeFile(JSON.stringify({ enabled: true, mode, port, token: randomBytes(32).toString('hex'),
        roots: { songs: { path: actualRoot.replaceAll('\\', '/'), read: true, write: true } },
        publisher_node: process.execPath.replaceAll('\\', '/'), publisher_script: fileURLToPath(new URL('./publish.js', import.meta.url)).replaceAll('\\', '/'),
      }, null, 2) + '\n');
      await file.sync();
    } finally { await file.close(); }
    process.stdout.write(`Configuration created: ${resolve(path)}\nSet BOSCA_MCP_CONFIG to this file before starting Bosca, and pass --config to the MCP server.\n`);
  } catch (error) {
    process.stderr.write(`Configuration was not created: ${error instanceof Error ? error.message : 'Unknown error'}\n`);
    process.exitCode = 1;
  }
}
