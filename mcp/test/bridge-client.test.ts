import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createServer, type Socket } from 'node:net';
import { once } from 'node:events';
import { BridgeClient, BridgeError, MAX_MESSAGE_BYTES } from '../src/bridge-client.js';

async function fixture(handler: (request: any, socket: Socket) => void, timeout = 1000) {
  const sockets = new Set<Socket>();
  let calls = 0;
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    let text = '';
    socket.on('data', chunk => {
      text += chunk.toString();
      for (;;) {
        const newline = text.indexOf('\n');
        if (newline < 0) break;
        const request = JSON.parse(text.slice(0, newline));
        text = text.slice(newline + 1);
        if (request.method === 'hello') {
          assert.equal(request.params.token, 'x'.repeat(32));
          socket.write(JSON.stringify({ id: request.id, result: { bridge_version: 1, instance_id: 'test' } }) + '\n');
        } else {
          calls++;
          handler(request, socket);
        }
      }
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  assert(address && typeof address !== 'string');
  const bridge = new BridgeClient({ enabled: true, port: address.port, token: 'x'.repeat(32) }, timeout);
  return { bridge, calls: () => calls, close: async () => {
    bridge.close();
    for (const socket of sockets) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
  } };
}

test('correlates concurrent requests and reassembles split UTF-8', async () => {
  const received: any[] = [];
  const f = await fixture((request, socket) => {
    received.push(request);
    if (received.length !== 2) return;
    const buffer = Buffer.from(received.reverse().map(r => JSON.stringify({ id: r.id, result: { value: r.params.value, name: '鋼琴' } }) + '\n').join(''));
    const split = buffer.indexOf(Buffer.from('鋼')) + 1;
    socket.write(buffer.subarray(0, split));
    setTimeout(() => socket.write(buffer.subarray(split)), 5);
  });
  try {
    const results = await Promise.all([f.bridge.call('query', { value: 1 }), f.bridge.call('query', { value: 2 })]);
    assert.deepEqual(results, [{ value: 1, name: '鋼琴' }, { value: 2, name: '鋼琴' }]);
  } finally { await f.close(); }
});

test('surfaces domain errors without disconnecting or changing their code', async () => {
  const f = await fixture((request, socket) => socket.write(JSON.stringify({ id: request.id, error: { code: 'REVISION_CONFLICT', message: 'Read again.', details: { current_revision: 4 } } }) + '\n'));
  try {
    await assert.rejects(f.bridge.call('edit'), (e: BridgeError) => e.code === 'REVISION_CONFLICT' && (e.details as any).current_revision === 4);
    await assert.rejects(f.bridge.call('edit'), (e: BridgeError) => e.code === 'REVISION_CONFLICT');
    assert.equal(f.calls(), 2);
  } finally { await f.close(); }
});

test('does not replay timed-out mutations', async () => {
  const f = await fixture(() => {}, 30);
  try {
    await assert.rejects(f.bridge.call('edit'), (e: BridgeError) => e.code === 'TIMEOUT');
    assert.equal(f.calls(), 1);
  } finally { await f.close(); }
});

test('rejects oversized requests before sending them', async () => {
  const f = await fixture(() => {});
  try {
    await assert.rejects(f.bridge.call('edit', { text: 'x'.repeat(MAX_MESSAGE_BYTES) }), (e: BridgeError) => e.code === 'LIMIT_EXCEEDED');
    assert.equal(f.calls(), 0);
  } finally { await f.close(); }
});

test('invalid JSON rejects all pending calls and a later query reconnects', async () => {
  let broken = true;
  const f = await fixture((request, socket) => {
    if (broken) socket.write('not JSON\n');
    else socket.write(JSON.stringify({ id: request.id, result: { ready: true } }) + '\n');
  });
  try {
    await assert.rejects(f.bridge.call('query'), (e: BridgeError) => e.code === 'INVALID_RESPONSE');
    broken = false;
    assert.deepEqual(await f.bridge.call('query'), { ready: true });
  } finally { await f.close(); }
});

test('disconnect leaves mutation outcome unknown and never silently retries', async () => {
  const f = await fixture((_request, socket) => socket.destroy());
  try {
    await assert.rejects(f.bridge.call('edit'), (e: BridgeError) => e.code === 'OUTCOME_UNKNOWN');
    assert.equal(f.calls(), 1);
  } finally { await f.close(); }
});
