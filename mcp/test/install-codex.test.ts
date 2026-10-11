import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { registerCodex, unregisterCodex } from '../dist/install-codex.js';
import type { Runner } from '../src/install-codex.js';

function fakeCodex() {
  const state = { entry: null as any, adds: 0, removes: 0 };
  const run: Runner = args => {
    if (args[1] === 'get') return state.entry
      ? { status: 0, stdout: JSON.stringify({ transport: { type: 'stdio', ...state.entry } }), stderr: '' }
      : { status: 1, stdout: '', stderr: 'No MCP server named bosca-ceoil found.' };
    if (args[1] === 'add') { state.adds++; state.entry = { command: args[4], args: args.slice(5) }; }
    else if (args[1] === 'remove') { state.removes++; state.entry = null; }
    else throw new Error('Unexpected command');
    return { status: 0, stdout: '', stderr: '' };
  };
  return { state, run };
}

test('Codex quick install is idempotent, preserves the token, and uninstall leaves songs/settings', async () => {
  const root = await mkdtemp(join(tmpdir(), 'bosca-setup-'));
  const configDir = join(root, 'private');
  const songsDir = join(root, 'songs with spaces');
  const { state, run } = fakeCodex();
  try {
    await registerCodex({ configDir, songsDir }, run);
    assert.equal(state.adds, 1);
    const first = JSON.parse(await readFile(join(configDir, 'mcp.json'), 'utf8'));
    assert.equal(first.mode, 'read_only');
    await writeFile(join(songsDir, 'keep.ceol'), 'user song');
    await registerCodex({ configDir, songsDir, mode: 'edit' }, run);
    const second = JSON.parse(await readFile(join(configDir, 'mcp.json'), 'utf8'));
    assert.equal(second.token, first.token);
    assert.equal(second.mode, 'edit');
    assert.equal(state.adds, 1);
    await unregisterCodex(configDir, undefined, run);
    assert.equal(state.removes, 1);
    assert.equal(await readFile(join(songsDir, 'keep.ceol'), 'utf8'), 'user song');
    assert.equal(JSON.parse(await readFile(join(configDir, 'mcp.json'), 'utf8')).token, first.token);
  } finally { await rm(root, { recursive: true }); }
});

test('Codex install and uninstall do not overwrite or remove unrelated entries', async () => {
  const root = await mkdtemp(join(tmpdir(), 'bosca-setup-conflict-'));
  const configDir = join(root, 'private');
  const songsDir = join(root, 'songs');
  const { state, run } = fakeCodex();
  try {
    state.entry = { command: 'another-server.exe', args: [] };
    await assert.rejects(registerCodex({ configDir, songsDir }, run), /different bosca-ceoil entry/);
    assert.equal(state.adds, 0);
    state.entry = null;
    await registerCodex({ configDir, songsDir }, run);
    state.entry = { command: 'another-server.exe', args: [] };
    assert.match(await unregisterCodex(configDir, undefined, run), /was preserved/);
    assert.equal(state.removes, 0);
    const anotherInstall = { command: 'C:/another-install/runtime/node.exe', args: ['C:/another-install/mcp/dist/index.js', '--config', join(configDir, 'mcp.json')] };
    state.entry = anotherInstall;
    await writeFile(join(configDir, 'codex-registration.json'), JSON.stringify(anotherInstall));
    assert.match(await unregisterCodex(configDir, undefined, run), /another Bosca installation/);
    assert.equal(state.removes, 0);
  } finally { await rm(root, { recursive: true }); }
});
