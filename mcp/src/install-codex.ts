import { spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile, rename, unlink, lstat } from 'node:fs/promises';
import { existsSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve, isAbsolute } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { randomUUID } from 'node:crypto';

export const SERVER_NAME = 'bosca-ceoil';
type Command = { command: string; args: string[] };
export type Runner = (args: string[]) => { status: number | null; stdout: string; stderr: string };
type Options = { configDir: string; songsDir: string; mode?: 'read_only' | 'edit'; codexCommand?: string };
const here = dirname(fileURLToPath(import.meta.url));

export function desktopCodexCandidates(localAppData: string): string[] {
  if (!isAbsolute(localAppData)) return [];
  const candidates: string[] = [];
  for (const bin of [join(localAppData, 'OpenAI', 'Codex', 'bin'),
    join(localAppData, 'Programs', 'OpenAI', 'Codex', 'bin')]) {
    // Desktop extracts its CLI into versioned directories. Other directories
    // here contain Node/rg, so only include those with an actual Codex binary.
    try {
      const versions = readdirSync(bin, { withFileTypes: true })
        .filter(entry => entry.isDirectory())
        .flatMap(entry => {
          const path = join(bin, entry.name, 'codex.exe');
          try { const info = statSync(path); return info.isFile() ? [{ path, modified: info.mtimeMs }] : []; }
          catch { return []; }
        }).sort((a, b) => b.modified - a.modified);
      candidates.push(...versions.map(entry => entry.path));
    } catch { /* This Desktop layout is not installed. */ }
    candidates.push(join(bin, 'codex.exe'));
  }
  return candidates;
}

export function findCodex(explicit?: string): string {
  if (explicit) {
    if (!isAbsolute(explicit) || !existsSync(explicit)) throw new Error('The selected Codex executable does not exist.');
    return explicit;
  }
  const candidates = desktopCodexCandidates(process.env.LOCALAPPDATA ?? join(homedir(), 'AppData', 'Local'));
  const found = spawnSync('where.exe', ['codex.exe'], { encoding: 'utf8', windowsHide: true, timeout: 3000 });
  if (found.status === 0) candidates.push(...found.stdout.trim().split(/\r?\n/));
  for (const path of candidates) if (isAbsolute(path) && existsSync(path)) return path;
  throw new Error('Codex CLI was not found. Install/open Codex, then use MCP Settings → Install in Codex again. You can also copy the host configuration into Codex Settings → MCP servers.');
}

function runner(command: string): Runner {
  return args => {
    const result = spawnSync(command, args, { encoding: 'utf8', windowsHide: true, timeout: 15000 });
    if (result.error) throw new Error(`Could not run Codex: ${result.error.message}`);
    return { status: result.status, stdout: result.stdout, stderr: result.stderr };
  };
}

async function readJson(path: string): Promise<any> {
  const info = await lstat(path);
  if (info.isSymbolicLink() || !info.isFile() || info.size > 65536) throw new Error('Invalid local setup file.');
  return JSON.parse(await readFile(path, 'utf8'));
}

async function writeJson(path: string, data: unknown) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify(data, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    await rename(temporary, path);
  } finally { await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
}

function getEntry(run: Runner): Command | null {
  const result = run(['mcp', 'get', SERVER_NAME, '--json']);
  if (result.status !== 0) {
    if (/No MCP server named|not found/i.test(result.stderr)) return null;
    throw new Error('Codex could not read its MCP configuration. Open Codex and resolve its configuration error before retrying.');
  }
  const data = JSON.parse(result.stdout);
  const transport = data.transport;
  if (transport?.type !== 'stdio' || typeof transport.command !== 'string' || !Array.isArray(transport.args)) {
    throw new Error('A different server already uses the name bosca-ceoil. Rename or remove that entry in Codex first.');
  }
  return { command: transport.command, args: transport.args };
}

function same(a: Command | null, b: Command | null): boolean {
  return !!a && !!b && a.command === b.command && JSON.stringify(a.args) === JSON.stringify(b.args);
}

export async function registerCodex(options: Options, injectedRunner?: Runner): Promise<string> {
  if (!isAbsolute(options.configDir) || !isAbsolute(options.songsDir)) throw new Error('Setup paths must be absolute.');
  const run = injectedRunner ?? runner(findCodex(options.codexCommand));
  const configPath = join(options.configDir, 'mcp.json');
  const receiptPath = join(options.configDir, 'codex-registration.json');
  const desired = { command: process.execPath, args: [join(here, 'index.js'), '--config', configPath] };
  const existing = getEntry(run);
  const receipt: Command | null = existsSync(receiptPath) ? await readJson(receiptPath) : null;
  if (existing && !same(existing, desired) && !same(existing, receipt)) {
    throw new Error('A different bosca-ceoil entry already exists in Codex. It was left unchanged. Rename/remove it in Codex Settings → MCP servers before retrying.');
  }
  await mkdir(options.configDir, { recursive: true });
  let root = options.songsDir;
  let mode = options.mode ?? 'read_only';
  let port = 37641;
  const update = existsSync(configPath);
  if (update) {
    const prior = await readJson(configPath);
    if (typeof prior.roots?.songs?.path !== 'string' || !['read_only', 'edit'].includes(prior.mode)) throw new Error('Existing MCP configuration is invalid; repair it in MCP Settings first.');
    root = prior.roots.songs.path;
    mode = options.mode ?? prior.mode;
    port = prior.port;
  } else { await mkdir(root, { recursive: true }); }
  const configured = spawnSync(process.execPath, [join(here, 'configure.js'), '--config', configPath,
    '--root', root, '--mode', mode, '--port', String(port), '--enabled', 'true', '--update', String(update)],
  { encoding: 'utf8', windowsHide: true, timeout: 15000 });
  if (configured.status !== 0) throw new Error('Could not create/update the protected MCP configuration. Check the song directory and file permissions.');
  if (!same(existing, desired)) {
    const result = run(['mcp', 'add', SERVER_NAME, '--', desired.command, ...desired.args]);
    if (result.status !== 0) throw new Error('Codex could not register the server. Your song configuration is retained; retry from MCP Settings.');
  }
  if (!same(getEntry(run), desired)) throw new Error('Codex registration could not be verified.');
  await writeJson(receiptPath, desired);
  return `Bosca is connected to Codex (${mode === 'edit' ? 'editing enabled' : 'read only'}). Restart MCP servers in Codex Settings, or restart Codex. Keep Bosca open while using its tools.`;
}

export async function unregisterCodex(configDir: string, explicit?: string, injectedRunner?: Runner): Promise<string> {
  const receiptPath = join(configDir, 'codex-registration.json');
  if (!existsSync(receiptPath)) return 'No owned Codex registration to remove. Songs and settings were preserved.';
  const receipt: Command = await readJson(receiptPath);
  if (receipt.command !== process.execPath || receipt.args[0] !== join(here, 'index.js')) {
    return 'The Codex registration belongs to another Bosca installation and was preserved.';
  }
  const run = injectedRunner ?? runner(findCodex(explicit));
  const existing = getEntry(run);
  if (existing && !same(existing, receipt)) return 'Codex entry was changed outside Bosca and was preserved. Songs and settings were preserved.';
  if (existing && run(['mcp', 'remove', SERVER_NAME]).status !== 0) throw new Error('Remove bosca-ceoil manually in Codex Settings → MCP servers.');
  await unlink(receiptPath);
  return 'Codex registration removed. Songs and settings were preserved.';
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let resultPath: string | undefined;
  try {
    const { values } = parseArgs({ options: { action: { type: 'string', default: 'register' },
      'config-dir': { type: 'string' }, 'songs-dir': { type: 'string' }, mode: { type: 'string' },
      'codex-command': { type: 'string' } } });
    if (!['register', 'unregister'].includes(values.action!) || (values.mode && !['read_only', 'edit'].includes(values.mode))) throw new Error('Invalid setup options.');
    const configDir = values['config-dir'] ?? join(process.env.LOCALAPPDATA ?? join(homedir(), 'AppData', 'Local'), 'BoscaCeoilBlueMCP');
    if (!isAbsolute(configDir)) throw new Error('Configuration directory must be absolute.');
    await mkdir(configDir, { recursive: true });
    resultPath = join(configDir, 'setup-result.json');
    const message = values.action === 'unregister'
      ? await unregisterCodex(configDir, values['codex-command'])
      : await registerCodex({ configDir, songsDir: values['songs-dir'] ?? join(homedir(), 'Documents', 'Bosca Ceoil Blue'),
        mode: values.mode as Options['mode'], codexCommand: values['codex-command'] });
    await writeJson(resultPath, { ok: true, message });
    process.stdout.write(message + '\n');
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Setup failed.';
    if (resultPath) await writeJson(resultPath, { ok: false, message });
    process.stderr.write(message + '\n');
    process.exitCode = 1;
  }
}
