import { McpServer, ResourceTemplate } from '@modelcontextprotocol/server';
import * as z from 'zod/v4';
import { BridgeClient, BridgeError } from './bridge-client.js';
import { editingTools } from './contracts.js';

export function createServer(bridge: BridgeClient): McpServer {
  const server = new McpServer({ name: 'bosca-ceoil-blue', version: '0.1.0' });
  const tools = [
    { name: 'bosca_status', description: 'Read Bosca connection, song revision, playback state and capacity limits.', schema: z.object({}).strict() },
    { name: 'bosca_job_get', description: 'Read an export job. Only succeeded means the output file has been published. Errors and cancellation are explicit terminal states.', schema: z.object({ job_id: z.string().min(1).max(128) }).strict() },
    { name: 'bosca_song_get', description: 'Read the current song summary and instruments, without all notes. Does not change the song.', schema: z.object({}).strict() },
    { name: 'bosca_catalog_list', description: 'List available voices, drum mappings, scales or effects. voice_id is the catalog ID; drum_index is not a MIDI note.', schema: z.object({
      kind: z.enum(['voices', 'scales', 'effects']).default('voices'),
      filter: z.string().max(128).default(''), cursor: z.number().int().min(0).max(10_000).default(0),
      limit: z.number().int().min(1).max(200).default(50),
    }).strict() },
    { name: 'bosca_pattern_get', description: 'Read one zero-based pattern. Positions and lengths are sequencer steps (4 steps per beat). Drum notes use drum_index, melodic notes use pitch.', schema: z.object({ pattern_index: z.number().int().min(0).max(4095) }).strict() },
    { name: 'bosca_arrangement_get', description: 'Read timeline bars and eight channels. Each bar has pattern_size steps, not necessarily four beats. Empty cells are null; loop end is exclusive.', schema: z.object({
      start: z.number().int().min(0).max(999).default(0), count: z.number().int().min(1).max(128).default(16),
    }).strict() },
  ];
  const operationTool = { name: 'bosca_operation_get', description: 'Recover a retained operation outcome after a timeout. Cache covers 256 operations for 10 minutes in one application instance.', schema: z.object({ instance_id: z.string().min(1).max(128), operation_id: z.string().min(1).max(128) }).strict() };
  for (const tool of [...tools, operationTool, ...editingTools]) {
    const readOnly = !editingTools.some(edit => edit.name === tool.name);
    server.registerTool(tool.name, {
      description: tool.description, inputSchema: tool.schema,
      annotations: { readOnlyHint: readOnly, destructiveHint: !readOnly, idempotentHint: readOnly, openWorldHint: false },
    }, async params => {
      try {
        const result = await bridge.call(tool.name, params);
        return { content: [{ type: 'text' as const, text: JSON.stringify(result) }], structuredContent: result };
      } catch (error) {
        const result = error instanceof BridgeError
          ? { code: error.code, message: error.message, details: error.details }
          : { code: 'INTERNAL_ERROR', message: 'Unexpected automation failure.' };
        return { isError: true, content: [{ type: 'text' as const, text: JSON.stringify(result) }] };
      }
    });
  }
  for (const [name, uri, method] of [
    ['status', 'bosca://status', 'bosca_status'],
    ['song', 'bosca://song/current', 'bosca_song_get'],
    ['voices', 'bosca://catalog/voices', 'bosca_catalog_list'],
  ] as const) {
    server.registerResource(name, uri, { mimeType: 'application/json' }, async url => ({
      contents: [{ uri: url.href, mimeType: 'application/json', text: JSON.stringify(await bridge.call(method)) }],
    }));
  }
  server.registerResource('pattern', new ResourceTemplate('bosca://song/current/pattern/{index}', { list: undefined }),
    { mimeType: 'application/json' }, async (url, variables) => {
      const index = z.coerce.number().int().min(0).max(4095).parse(variables.index);
      return { contents: [{ uri: url.href, mimeType: 'application/json', text: JSON.stringify(await bridge.call('bosca_pattern_get', { pattern_index: index })) }] };
    });
  return server;
}
