import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

test('configuration creation, protected updates and token rotation preserve the original on errors', async () => {
  const root = await mkdtemp(join(tmpdir(), 'bosca-config-'));
  const config = join(root, 'mcp.json');
  const run = (...args: string[]) => spawnSync(process.execPath, [resolve('dist/configure.js'), '--config', config, '--root', root, ...args], { encoding: 'utf8', windowsHide: true });
  try {
    assert.equal(run().status, 0);
    const original = await readFile(config, 'utf8');
    const first = JSON.parse(original);
    assert.equal(first.mode, 'read_only');
    assert.equal(first.token.length, 64);
    assert.equal(run().status, 1);
    assert.equal(await readFile(config, 'utf8'), original);
    assert.equal(run('--update', 'true', '--mode', 'edit', '--port', '37642', '--enabled', 'false').status, 0);
    const updated = JSON.parse(await readFile(config, 'utf8'));
    assert.equal(updated.token, first.token);
    assert.equal(updated.mode, 'edit');
    assert.equal(updated.enabled, false);
    assert.equal(updated.port, 37642);
    updated.roots.songs.write = false;
    await writeFile(config, JSON.stringify(updated));
    assert.equal(run('--update', 'true').status, 0);
    assert.equal(JSON.parse(await readFile(config, 'utf8')).roots.songs.write, false);
    const beforeFailure = await readFile(config, 'utf8');
    assert.equal(run('--update', 'true', '--port', '1').status, 1);
    assert.equal(await readFile(config, 'utf8'), beforeFailure);
    assert.equal(run('--update', 'true', '--rotate', 'true').status, 0);
    assert.notEqual(JSON.parse(await readFile(config, 'utf8')).token, first.token);
    assert.deepEqual(await readdir(root), ['mcp.json']);
  } finally { await rm(root, { recursive: true }); }
});
