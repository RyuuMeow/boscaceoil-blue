import { serveStdio } from '@modelcontextprotocol/server/stdio';
import { BridgeClient, readConfig } from './bridge-client.js';
import { createServer } from './server.js';

const args = process.argv.slice(2);
const configPath = args.length === 2 && args[0] === '--config' ? args[1] : process.env.BOSCA_MCP_CONFIG;
if (!configPath || (args.length !== 0 && !(args.length === 2 && args[0] === '--config'))) {
  process.stderr.write('Usage: node dist/index.js --config <absolute path to mcp.json>\n');
  process.exitCode = 1;
} else {
  try {
    const bridge = new BridgeClient(await readConfig(configPath));
    const handle = serveStdio(() => createServer(bridge), {
      legacy: 'serve', onerror: () => process.stderr.write('MCP protocol error.\n'),
    });
    const close = () => { bridge.close(); void handle.close(); };
    process.stdin.once('end', close);
    process.once('SIGINT', close);
    process.once('SIGTERM', close);
  } catch {
    process.stderr.write('Cannot load MCP configuration. Verify enabled, port, token and file permissions.\n');
    process.exitCode = 1;
  }
}
