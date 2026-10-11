import { createConnection, type Socket } from 'node:net';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import * as z from 'zod/v4';

const configSchema = z.object({
  enabled: z.literal(true),
  port: z.number().int().min(1024).max(65535).default(37641),
  token: z.string().min(32).max(256),
});
export type BridgeConfig = z.infer<typeof configSchema>;
export const MAX_MESSAGE_BYTES = 1_048_576;
const MAX_PENDING = 32;

export class BridgeError extends Error {
  constructor(public readonly code: string, message: string, public readonly details: unknown = {}) {
    super(message);
  }
}

export async function readConfig(path: string): Promise<BridgeConfig> {
  const data = await readFile(path);
  if (data.length > 65_536) throw new Error('MCP configuration exceeds 64 KiB.');
  return configSchema.parse(JSON.parse(data.toString('utf8')));
}

type Pending = {
  resolve: (result: Record<string, unknown>) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

/** One authenticated loopback connection; requests are never automatically replayed. */
export class BridgeClient {
  private socket?: Socket;
  private connecting?: Promise<void>;
  private input = Buffer.alloc(0);
  private pending = new Map<string, Pending>();
  private closed = false;

  constructor(private readonly config: BridgeConfig, private readonly timeoutMs = 10_000) {}

  async call(method: string, params: Record<string, unknown> = {}): Promise<Record<string, unknown>> {
    await this.connect();
    return this.send(method, params);
  }

  close(): void {
    this.closed = true;
    this.disconnect(new BridgeError('APP_NOT_CONNECTED', 'MCP connection closed.'));
  }

  private async connect(): Promise<void> {
    if (this.closed) throw new BridgeError('APP_NOT_CONNECTED', 'MCP connection closed.');
    if (this.connecting) return this.connecting;
    if (this.socket && !this.socket.destroyed) return;
    this.connecting = this.open();
    try { await this.connecting; }
    finally { this.connecting = undefined; }
  }

  private async open(): Promise<void> {
    const socket = createConnection({ host: '127.0.0.1', port: this.config.port });
    this.socket = socket;
    socket.setNoDelay(true);
    socket.on('data', chunk => this.receive(socket, chunk));
    socket.on('error', () => {
      if (this.socket === socket) this.disconnect(new BridgeError('APP_NOT_CONNECTED', 'Cannot connect to Bosca. Check that MCP is enabled and the port is correct.'));
    });
    socket.on('close', () => {
      if (this.socket === socket) this.disconnect(new BridgeError('OUTCOME_UNKNOWN', 'Bosca disconnected. Re-read state before retrying a mutation.'));
    });
    try {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => {
          cleanup();
          reject(new BridgeError('TIMEOUT', 'Connection timed out.'));
        }, this.timeoutMs);
        const cleanup = () => {
          clearTimeout(timer);
          socket.off('connect', connected);
          socket.off('error', failed);
          socket.off('close', failed);
        };
        const connected = () => { cleanup(); resolve(); };
        const failed = () => { cleanup(); reject(new BridgeError('APP_NOT_CONNECTED', 'Bosca is not accepting a connection.')); };
        socket.once('connect', connected);
        socket.once('error', failed);
        socket.once('close', failed);
      });
      const hello = await this.send('hello', { token: this.config.token, bridge_version: 1 });
      if (hello.bridge_version !== 1 || typeof hello.instance_id !== 'string') {
        throw new BridgeError('UNSUPPORTED_VERSION', 'Expected Bosca bridge version 1.');
      }
    } catch (error) {
      if (this.socket === socket) this.disconnect(error instanceof Error ? error : new Error('Connection failed.'));
      throw error;
    }
  }

  private send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    const socket = this.socket;
    if (!socket || socket.destroyed) return Promise.reject(new BridgeError('APP_NOT_CONNECTED', 'Bosca is disconnected.'));
    if (this.pending.size >= MAX_PENDING) return Promise.reject(new BridgeError('APP_BUSY', 'Too many pending requests.'));
    const id = randomUUID();
    const payload = Buffer.from(JSON.stringify({ id, method, params }) + '\n');
    if (payload.length > MAX_MESSAGE_BYTES) return Promise.reject(new BridgeError('LIMIT_EXCEEDED', 'Request exceeds 1 MiB.'));
    if (socket.writableLength + payload.length > MAX_MESSAGE_BYTES * 2) return Promise.reject(new BridgeError('APP_BUSY', 'Bridge write queue is full.'));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new BridgeError('TIMEOUT', 'Request timed out; do not replay a mutation with a new operation_id.'));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      socket.write(payload);
    });
  }

  private receive(socket: Socket, chunk: Buffer): void {
    if (socket !== this.socket) return;
    this.input = Buffer.concat([this.input, chunk]);
    if (this.input.length > MAX_MESSAGE_BYTES * 2) {
      this.disconnect(new BridgeError('LIMIT_EXCEEDED', 'Bridge response buffer exceeded its limit.'));
      return;
    }
    for (;;) {
      const newline = this.input.indexOf(10);
      if (newline < 0) {
        if (this.input.length > MAX_MESSAGE_BYTES) this.disconnect(new BridgeError('LIMIT_EXCEEDED', 'Bridge response exceeds 1 MiB.'));
        return;
      }
      if (newline > MAX_MESSAGE_BYTES) {
        this.disconnect(new BridgeError('LIMIT_EXCEEDED', 'Bridge response exceeds 1 MiB.'));
        return;
      }
      const line = this.input.subarray(0, newline);
      this.input = this.input.subarray(newline + 1);
      try {
        const response = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line));
        if (!response || typeof response.id !== 'string' || (!response.result && !response.error)) throw new Error('Invalid envelope.');
        const pending = this.pending.get(response.id);
        if (!pending) continue; // Late response to a request whose caller timed out.
        clearTimeout(pending.timer);
        this.pending.delete(response.id);
        if (response.error) {
          pending.reject(new BridgeError(String(response.error.code), String(response.error.message), response.error.details));
        } else {
          pending.resolve(response.result);
        }
      } catch {
        this.disconnect(new BridgeError('INVALID_RESPONSE', 'Bosca returned an invalid response.'));
        return;
      }
    }
  }

  private disconnect(error: Error): void {
    const socket = this.socket;
    this.socket = undefined;
    this.input = Buffer.alloc(0);
    socket?.destroy();
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
