import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

test('official client discovers tools/resources and receives structured disconnected errors', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'bosca-mcp-'));
  const config = join(directory, 'config.json');
  await writeFile(config, JSON.stringify({ enabled: true, port: 65534, token: 'x'.repeat(32) }));
  const transport = new StdioClientTransport({ command: process.execPath,
    args: [resolve('dist/index.js'), '--config', config], stderr: 'pipe' });
  const client = new Client({ name: 'bosca-test', version: '1.0.0' });
  try {
    await client.connect(transport);
    const { tools } = await client.listTools();
    assert(tools.some(t => t.name === 'bosca_status'));
    const { resources } = await client.listResources();
    assert(resources.some(r => r.uri === 'bosca://song/current'));
    const result = await client.callTool({ name: 'bosca_status', arguments: {} });
    assert.equal(result.isError, true);
    assert.equal(JSON.parse((result.content[0] as any).text).code, 'APP_NOT_CONNECTED');
  } finally {
    await client.close();
    await rm(directory, { recursive: true });
  }
});

test('stdio EOF exits even when no protocol handshake has occurred', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'bosca-mcp-eof-'));
  const config = join(directory, 'config.json');
  await writeFile(config, JSON.stringify({ enabled: true, port: 65534, token: 'x'.repeat(32) }));
  try {
    const child = spawn(process.execPath, [resolve('dist/index.js'), '--config', config], { stdio: 'pipe' });
    let output = '';
    child.stdout.on('data', b => output += b);
    const exited = new Promise<number | null>((resolve, reject) => {
      const timer = setTimeout(() => { child.kill(); reject(new Error('Server stayed alive after stdin EOF.')); }, 3000);
      child.once('exit', code => { clearTimeout(timer); resolve(code); });
      child.once('error', reject);
    });
    child.stdin.end();
    assert.equal(await exited, 0);
    assert.equal(output, '');
  } finally { await rm(directory, { recursive: true }); }
});
