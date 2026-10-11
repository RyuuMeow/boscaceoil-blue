import { randomBytes } from 'node:crypto';
import { lstat, mkdir, open, realpath, readFile, rename, unlink } from 'node:fs/promises';
import { dirname, isAbsolute, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const args = process.argv.slice(2);
const values = new Map<string, string>();
let valid = args.length % 2 === 0;
for (let i = 0; i < args.length; i += 2) {
  const key = args[i]!;
  const value = args[i + 1];
  if (!['--config', '--root', '--mode', '--port', '--update', '--enabled', '--rotate'].includes(key) || !value || values.has(key)) valid = false;
  else values.set(key, value);
}
const path = values.get('--config');
const root = values.get('--root');
const mode = values.get('--mode') ?? 'read_only';
const port = Number(values.get('--port') ?? '37641');
for (const key of ['--update', '--enabled', '--rotate']) {
  if (values.has(key) && !['true', 'false'].includes(values.get(key)!)) valid = false;
}
if (!valid || !path || !root || !isAbsolute(path) || !isAbsolute(root) || !['read_only', 'edit'].includes(mode) || !Number.isInteger(port) || port < 1024 || port > 65535) {
  process.stderr.write('Usage: node dist/configure.js --config <absolute file> --root <existing song directory> [--mode read_only|edit] [--port 37641]\n');
  process.exitCode = 1;
} else {
  try {
    const rootInfo = await lstat(root);
    if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) throw new Error('Select an existing, unlinked song directory.');
    const actualRoot = await realpath(root);
    await mkdir(dirname(path), { recursive: true });
    const update = values.get('--update') === 'true';
    const previousText = update ? await readFile(path, 'utf8') : undefined;
    const previous = previousText ? JSON.parse(previousText) : {};
    if (update && (await lstat(path)).isSymbolicLink()) throw new Error('Configuration must not be a symbolic link.');
    const outputPath = update ? `${path}.${randomBytes(16).toString('hex')}.tmp` : path;
    const file = await open(outputPath, 'wx', 0o600);
    let completed = false;
    try {
      // Windows ignores POSIX mode bits. Protect the file before writing the token.
      if (process.platform === 'win32') {
        const identity = spawnSync('whoami.exe', [], { encoding: 'utf8', windowsHide: true });
        if (identity.status !== 0) throw new Error('Cannot determine the Windows account for file permissions.');
        const acl = spawnSync('icacls.exe', [resolve(outputPath), '/inheritance:r', '/grant:r', `${identity.stdout.trim()}:(F)`], { windowsHide: true });
        if (acl.status !== 0) throw new Error('Cannot protect the MCP configuration file.');
      }
      const token = update && values.get('--rotate') !== 'true' ? previous.token : randomBytes(32).toString('hex');
      if (typeof token !== 'string' || token.length < 32 || token.length > 256) throw new Error('Invalid existing token; request rotation.');
      await file.writeFile(JSON.stringify({ ...previous, enabled: values.get('--enabled') !== 'false', mode, port, token,
        roots: { ...previous.roots, songs: { path: actualRoot.replaceAll('\\', '/'), read: true, write: true } },
        publisher_node: process.execPath.replaceAll('\\', '/'), publisher_script: fileURLToPath(new URL('./publish.js', import.meta.url)).replaceAll('\\', '/'),
      }, null, 2) + '\n');
      await file.sync();
      completed = true;
    } finally { await file.close(); if (!completed) await unlink(outputPath); }
    if (update) {
      try {
        if (await readFile(path, 'utf8') !== previousText) throw new Error('Configuration changed concurrently; reload before updating.');
        await rename(outputPath, path);
      } catch (error) { await unlink(outputPath); throw error; }
    }
    process.stdout.write(`Configuration created: ${resolve(path)}\nSet BOSCA_MCP_CONFIG to this file before starting Bosca, and pass --config to the MCP server.\n`);
  } catch (error) {
    process.stderr.write(`Configuration was not created: ${error instanceof Error ? error.message : 'Unknown error'}\n`);
    process.exitCode = 1;
  }
}
