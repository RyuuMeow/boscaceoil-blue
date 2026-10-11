import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { randomBytes, randomUUID } from 'node:crypto';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { BridgeClient } from '../../src/bridge-client.js';

test('real MCP client edits, undoes, saves and reloads the real Godot application', { timeout: 60_000 }, async () => {
  const godot = process.env.BOSCA_GODOT;
  assert(godot, 'Set BOSCA_GODOT to Godot 4.3 (with GDSiON installed and project imported).');
  const temporary = await mkdtemp(join(tmpdir(), 'bosca-runtime-'));
  const songs = join(temporary, 'songs');
  await mkdir(songs);
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const address = reservation.address();
  assert(address && typeof address !== 'string');
  const port = address.port;
  await new Promise<void>(done => reservation.close(() => done()));
  const configPath = join(temporary, 'mcp.json');
  const token = randomBytes(32).toString('hex');
  await writeFile(configPath, JSON.stringify({ enabled: true, mode: 'edit', port, token,
    roots: { songs: { path: songs.replaceAll('\\', '/'), read: true, write: true } },
    publisher_node: process.execPath, publisher_script: resolve('dist/publish.js'),
  }), { mode: 0o600 });
  const app = spawn(godot, ['--headless', '--path', resolve('..'), 'res://tests/automation/runtime.tscn'], {
    env: { ...process.env, BOSCA_MCP_CONFIG: configPath, APPDATA: temporary, XDG_DATA_HOME: temporary },
    stdio: 'pipe', windowsHide: true,
  });
  let logs = '';
  app.stdout.on('data', data => logs += data);
  app.stderr.on('data', data => logs += data);
  const transport = new StdioClientTransport({ command: process.execPath, args: [resolve('dist/index.js'), '--config', configPath], stderr: 'pipe' });
  const client = new Client({ name: 'bosca-integration', version: '1.0.0' });
  const raw = new BridgeClient({ enabled: true, port, token }, 1000);
  try {
    let ready = false;
    for (let attempt = 0; attempt < 50; attempt++) {
      assert(app.exitCode === null, `Godot exited during startup:\n${logs}`);
      try { await raw.call('bosca_status'); ready = true; break; }
      catch { await new Promise(done => setTimeout(done, 100)); }
    }
    raw.close();
    assert(ready, `Godot bridge did not start:\n${logs}`);
    await new Promise(done => setTimeout(done, 100)); // Let Godot observe the discovery socket closing.
    await client.connect(transport);
    async function call(name: string, args: Record<string, unknown> = {}) {
      const response = await client.callTool({ name, arguments: args });
      const text = response.content.find(item => item.type === 'text');
      assert(text && text.type === 'text');
      const data = JSON.parse(text.text);
      assert(!response.isError, `${name}: ${JSON.stringify(data)}\n${logs}`);
      return data;
    }
    async function edit(name: string, args: Record<string, unknown> = {}) {
      const status = await call('bosca_status');
      return call(name, { instance_id: status.instance_id, song_id: status.song_id,
        expected_revision: status.revision, operation_id: randomUUID(), ...args });
    }
    assert((await client.listTools()).tools.length >= 20);
    const resource = await client.readResource({ uri: 'bosca://song/current' });
    assert.equal(JSON.parse((resource.contents[0] as any).text).bpm, 120);
    await edit('bosca_playback_set', { action: 'stop' });
    await edit('bosca_song_update', { bpm: 100 });
    const drums = await call('bosca_catalog_list', { kind: 'voices', filter: 'drum', limit: 200 });
    const drumVoice = drums.items.find((item: any) => item.type === 'drumkit');
    assert(drumVoice && drumVoice.drums.length > 0, 'No drumkit in catalog.');
    const drum = await edit('bosca_instrument_create', { voice_id: drumVoice.voice_id });
    const pattern = await edit('bosca_pattern_create', { instrument_index: drum.instrument_index });
    await edit('bosca_notes_set', { pattern_index: 0, mode: 'replace', notes: [
      { pitch: 60, position: 0, length: 4 }, { pitch: 64, position: 4, length: 4 }, { pitch: 67, position: 8, length: 8 },
    ] });
    await edit('bosca_notes_set', { pattern_index: pattern.pattern_index, mode: 'replace', notes: [
      { drum_index: 0, position: 0, length: 1 }, { drum_index: 0, position: 8, length: 1 },
    ] });
    const cells = Array.from({ length: 8 }, (_, bar) => [
      { bar, channel: 0, pattern_index: 0 }, { bar, channel: 1, pattern_index: pattern.pattern_index },
    ]).flat();
    await edit('bosca_arrangement_set', { cells });
    assert.equal((await call('bosca_arrangement_get')).timeline_length, 8);
    await edit('bosca_history_step', { action: 'undo' });
    assert.equal((await call('bosca_arrangement_get')).timeline_length, 1);
    await edit('bosca_history_step', { action: 'redo' });
    await edit('bosca_loop_set', { start: 0, end: 8 });
    await edit('bosca_playback_set', { action: 'play' });
    assert.equal((await call('bosca_status')).playing, true);
    await edit('bosca_playback_set', { action: 'stop' });
    await edit('bosca_song_save', { root_id: 'songs', relative_path: 'loop.ceol' });
    const saved = await readFile(join(songs, 'loop.ceol'), 'utf8');
    assert(saved.startsWith('3,'));
    const before = await call('bosca_pattern_get', { pattern_index: 0 });
    await edit('bosca_song_new');
    await edit('bosca_song_open', { root_id: 'songs', relative_path: 'loop.ceol' });
    const after = await call('bosca_pattern_get', { pattern_index: 0 });
    assert.deepEqual(after.notes, before.notes);
    assert.equal((await call('bosca_song_get')).bpm, 100);
    assert.equal((await call('bosca_arrangement_get')).timeline_length, 8);
    async function waitJob(id: string) {
      for (let i = 0; i < 200; i++) {
        const job = await call('bosca_job_get', { job_id: id });
        if (['succeeded', 'failed', 'cancelled'].includes(job.state)) return job;
        await new Promise(done => setTimeout(done, 50));
      }
      throw new Error('Export did not finish.');
    }
    const midiJob = await edit('bosca_export_start', { format: 'midi', root_id: 'songs', relative_path: 'loop.mid', start: 0, end: 1 });
    assert.equal((await waitJob(midiJob.job_id)).state, 'succeeded');
    const midi = await readFile(join(songs, 'loop.mid'));
    assert.equal(midi.subarray(0, 4).toString(), 'MThd');
    assert(midi.length > 30);
    const beforeExport = await call('bosca_song_get');
    const wavJob = await edit('bosca_export_start', { format: 'wav', root_id: 'songs', relative_path: 'loop.wav', start: 0, end: 1 });
    const exported = await waitJob(wavJob.job_id);
    assert.equal(exported.state, 'succeeded', JSON.stringify(exported));
    const wav = await readFile(join(songs, 'loop.wav'));
    assert.equal(wav.subarray(0, 4).toString(), 'RIFF');
    assert.equal(wav.subarray(8, 12).toString(), 'WAVE');
    assert(wav.length > 44);
    assert.equal((await call('bosca_status')).busy, false);
    assert.deepEqual((await call('bosca_song_get')).loop, beforeExport.loop);
    const cancelled = await edit('bosca_export_start', { format: 'wav', root_id: 'songs', relative_path: 'cancelled.wav', start: 0, end: 8 });
    const cancelledResult = await edit('bosca_job_cancel', { job_id: cancelled.job_id });
    assert.equal(cancelledResult.state, 'cancelled');
    assert.equal((await call('bosca_status')).busy, false);
    assert.deepEqual((await call('bosca_song_get')).loop, beforeExport.loop);
    await assert.rejects(readFile(join(songs, 'cancelled.wav')), { code: 'ENOENT' });
    assert(!logs.includes('SCRIPT ERROR'), logs);
  } finally {
    raw.close();
    await client.close();
    app.kill();
    if (app.exitCode === null) await once(app, 'exit');
    await rm(temporary, { recursive: true, force: true });
  }
});
