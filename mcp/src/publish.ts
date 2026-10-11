// Invoked by Bosca with a fixed argv array, never by a shell or directly by a tool.
// Node provides atomic replacement on Windows; Godot 4.3's generic rename does not.
import { lstat, realpath, rename, link, unlink, open } from 'node:fs/promises';
import { basename, dirname, isAbsolute, parse, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export async function publish(source: string, destination: string, root: string, overwrite: boolean): Promise<void> {
  if (![source, destination, root].every(isAbsolute)) throw new Error('PATH_NOT_ALLOWED');
  const normalizedRoot = resolve(root);
  // Reject symbolic links and Windows junctions anywhere in the configured root.
  for (let current = normalizedRoot; current !== parse(current).root; current = dirname(current)) {
    if ((await lstat(current)).isSymbolicLink()) throw new Error('PATH_NOT_ALLOWED');
  }
  const canonicalRoot = await realpath(normalizedRoot);
  if (dirname(resolve(source)) !== normalizedRoot || dirname(resolve(destination)) !== normalizedRoot) throw new Error('PATH_NOT_ALLOWED');
  if (await realpath(dirname(source)) !== canonicalRoot || await realpath(dirname(destination)) !== canonicalRoot) throw new Error('PATH_NOT_ALLOWED');
  if (!/^\.bosca-[a-f0-9]{32}\.(ceol|mid|wav)$/.test(basename(source))) throw new Error('PATH_NOT_ALLOWED');
  if (!/\.(ceol|mid|wav)$/.test(destination) || resolve(source) === resolve(destination)) throw new Error('PATH_NOT_ALLOWED');
  const staged = await lstat(source);
  if (!staged.isFile() || staged.isSymbolicLink() || staged.nlink !== 1) throw new Error('PATH_NOT_ALLOWED');
  try {
    const target = await lstat(destination);
    if (target.isSymbolicLink() || !target.isFile()) throw new Error('PATH_NOT_ALLOWED');
    if (!overwrite) throw new Error('FILE_EXISTS');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
  }
  const handle = await open(source, 'r+');
  try { await handle.sync(); } finally { await handle.close(); }
  if (overwrite) {
    // Atomic replacement: old file survives if this fails. Never unlink it first.
    await rename(source, destination);
  } else {
    // Atomic no-clobber publication, including when another writer wins the race.
    await link(source, destination);
    try { await unlink(source); } catch { /* Published successfully; only the staging name remains. */ }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [source, destination, root, overwrite] = process.argv.slice(2);
  if (!source || !destination || !root || !['true', 'false'].includes(overwrite ?? '')) {
    process.stdout.write(JSON.stringify({ code: 'INVALID_ARGUMENT' }));
    process.exitCode = 1;
  } else {
    try {
      await publish(source, destination, root, overwrite === 'true');
      process.stdout.write(JSON.stringify({ code: 'OK' }));
    } catch (error) {
      const known = error instanceof Error ? error.message : '';
      const code = (error as NodeJS.ErrnoException).code === 'EEXIST' ? 'FILE_EXISTS'
        : ['PATH_NOT_ALLOWED', 'FILE_EXISTS'].includes(known) ? known : 'IO_FAILED';
      process.stdout.write(JSON.stringify({ code }));
      process.exitCode = 1;
    }
  }
}
