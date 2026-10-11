import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn, type ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, writeFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

test('Windows installer, real Codex registration, exported app, and safe uninstall', { timeout: 180_000 }, async () => {
  assert.equal(process.platform, 'win32', 'Installer smoke tests require Windows.');
  const installer = process.env.BOSCA_INSTALLER_EXE;
  const codex = process.env.BOSCA_CODEX_EXE;
  assert(installer && codex, 'Set BOSCA_INSTALLER_EXE and BOSCA_CODEX_EXE to absolute executable paths.');
  const root = await mkdtemp(join(process.env.BOSCA_INSTALLER_TEST_ROOT ?? tmpdir(), 'bosca-installer-'));
  const installed = join(root, 'installed app');
  const codexHome = join(root, 'isolated codex');
  const local = join(root, 'local');
  const roaming = join(root, 'roaming');
  const configDir = join(local, 'BoscaCeoilBlueMCP');
  const songs = join(root, 'songs with spaces');
  const env = { ...process.env, CODEX_HOME: codexHome, LOCALAPPDATA: local, APPDATA: roaming, BOSCA_MCP_CONFIG: '' };
  await mkdir(codexHome, { recursive: true });
  await mkdir(join(roaming, 'boscaceoil-blue'), { recursive: true });
  await writeFile(join(codexHome, 'config.toml'), '[mcp_servers.keep_me]\ncommand = "unrelated.exe"\n');
  await writeFile(join(roaming, 'boscaceoil-blue', 'bosca.settings'), '[gui]\nscale=100\n');

  async function run(exe: string, args: string[], limit = 60_000) {
    const child = spawn(exe, args, { env, windowsHide: true, stdio: 'pipe' });
    let output = '';
    child.stdout.on('data', data => output += data);
    child.stderr.on('data', data => output += data);
    const timer = setTimeout(() => child.kill(), limit);
    try {
      const [code] = await once(child, 'exit');
      assert.equal(code, 0, `${exe} failed (${code}): ${output}`);
      return output;
    } finally { clearTimeout(timer); }
  }

  let app: ChildProcess | undefined;
  let client: Client | undefined;
  let appLog = '';
  try {
    await run(resolve(installer), ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', '/TASKS=', '/SMOKETEST=1', `/DIR=${installed}`, `/LOG=${join(root, 'install.log')}`], 90_000);
    const node = join(installed, 'runtime', 'node.exe');
    const helper = join(installed, 'mcp', 'dist', 'install-codex.js');
    const executable = join(installed, 'boscaceoil-blue.exe');
    assert((await stat(executable)).size > 80_000_000);
    const setupArgs = [helper, '--config-dir', configDir, '--songs-dir', songs, '--codex-command', codex];
    await run(node, setupArgs);
    const first = JSON.parse(await readFile(join(configDir, 'mcp.json'), 'utf8'));
    assert.equal(first.mode, 'read_only');
    const registration = JSON.parse(await run(codex, ['mcp', 'get', 'bosca-ceoil', '--json']));
    assert.equal(registration.transport.command, node);
    assert.equal(registration.transport.args[0], join(installed, 'mcp', 'dist', 'index.js'));
    await run(node, [...setupArgs, '--mode', 'edit']);
    const config = JSON.parse(await readFile(join(configDir, 'mcp.json'), 'utf8'));
    assert.equal(config.token, first.token);
    assert.equal(config.mode, 'edit');
    assert.equal(JSON.parse(await run(codex, ['mcp', 'get', 'keep_me', '--json'])).transport.command, 'unrelated.exe');

    app = spawn(executable, ['--headless'], { env, windowsHide: true, stdio: 'pipe' });
    app.stdout!.on('data', data => appLog += data);
    app.stderr!.on('data', data => appLog += data);
    const transport = new StdioClientTransport({ command: node, args: [join(installed, 'mcp', 'dist', 'index.js'), '--config', join(configDir, 'mcp.json')], stderr: 'pipe' });
    client = new Client({ name: 'installer-smoke', version: '1.0.0' });
    await client.connect(transport);
    async function call(name: string, args: Record<string, unknown> = {}) {
      const result = await client!.callTool({ name, arguments: args });
      const text = result.content.find(item => item.type === 'text');
      assert(text && text.type === 'text');
      const data = JSON.parse(text.text);
      if (result.isError) throw new Error(`${name}: ${JSON.stringify(data)}`);
      return data;
    }
    let ready = false;
    for (let i = 0; i < 60; i++) {
      assert(app.exitCode === null, appLog);
      try { assert.equal((await call('bosca_status')).mode, 'edit'); ready = true; break; }
      catch { await new Promise(done => setTimeout(done, 100)); }
    }
    assert(ready, `Installed app did not start the configured bridge:\n${appLog}`);
    assert.equal((await client.listTools()).tools.length, 23);
    async function edit(name: string, args: Record<string, unknown> = {}) {
      const status = await call('bosca_status');
      return call(name, { instance_id: status.instance_id, song_id: status.song_id, expected_revision: status.revision, operation_id: randomUUID(), ...args });
    }
    await edit('bosca_playback_set', { action: 'stop' });
    await edit('bosca_song_update', { bpm: 240 });
    await edit('bosca_notes_set', { pattern_index: 0, mode: 'replace', notes: [{ pitch: 60, position: 0, length: 4 }] });
    await edit('bosca_song_save', { root_id: 'songs', relative_path: 'installer.ceol' });
    for (const format of ['wav', 'midi']) {
      const filename = format === 'wav' ? 'installer.wav' : 'installer.mid';
      const job = await edit('bosca_export_start', { format, root_id: 'songs', relative_path: filename, start: 0, end: 1 });
      let completed = false;
      for (let i = 0; i < 200; i++) {
        const state = await call('bosca_job_get', { job_id: job.job_id });
        if (state.state === 'succeeded') { completed = true; break; }
        assert(!['failed', 'cancelled'].includes(state.state), JSON.stringify(state));
        await new Promise(done => setTimeout(done, 50));
      }
      assert(completed, `${format} export did not finish`);
      const bytes = await readFile(join(songs, filename));
      assert.equal(bytes.subarray(0, 4).toString(), format === 'wav' ? 'RIFF' : 'MThd');
      assert(bytes.length > 44);
    }
    assert.equal((await call('bosca_status')).busy, false);
    assert(!appLog.includes('SCRIPT ERROR'), appLog);
    await client.close(); client = undefined;
    app.kill(); if (app.exitCode === null) await once(app, 'exit'); app = undefined;
    await run(node, [helper, '--action', 'unregister', '--config-dir', configDir, '--codex-command', codex]);
    assert.equal(JSON.parse(await run(codex, ['mcp', 'get', 'keep_me', '--json'])).transport.command, 'unrelated.exe');
    await run(join(installed, 'unins000.exe'), ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SMOKETEST=1', `/LOG=${join(root, 'uninstall.log')}`]);
    await assert.rejects(stat(executable), { code: 'ENOENT' });
    assert((await readFile(join(songs, 'installer.ceol'), 'utf8')).startsWith('3,'));
    assert.equal(JSON.parse(await readFile(join(configDir, 'mcp.json'), 'utf8')).token, first.token);
  } finally {
    await client?.close();
    if (app && app.exitCode === null) { app.kill(); await once(app, 'exit'); }
    await writeFile(join(root, 'app.log'), appLog);
    console.log(`Installer smoke diagnostics: ${root}`);
  }
});
