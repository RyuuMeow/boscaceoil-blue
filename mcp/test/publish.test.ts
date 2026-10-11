import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, writeFile, readFile, rm, symlink, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { publish } from '../src/publish.js';

test('publishes without overwriting, replaces atomically only when requested', async () => {
  const root = await mkdtemp(join(tmpdir(), 'bosca-publish-'));
  const source = join(root, `.bosca-${'a'.repeat(32)}.ceol`);
  const destination = join(root, 'song.ceol');
  try {
    await writeFile(source, 'first');
    await publish(source, destination, root, false);
    assert.equal(await readFile(destination, 'utf8'), 'first');
    await writeFile(source, 'second');
    await assert.rejects(publish(source, destination, root, false), /FILE_EXISTS/);
    assert.equal(await readFile(destination, 'utf8'), 'first');
    assert.equal(await readFile(source, 'utf8'), 'second');
    await publish(source, destination, root, true);
    assert.equal(await readFile(destination, 'utf8'), 'second');
  } finally { await rm(root, { recursive: true }); }
});

test('rejects traversal, staging spoofing and linked roots', async () => {
  const base = await mkdtemp(join(tmpdir(), 'bosca-publish-path-'));
  const root = join(base, 'songs');
  const other = join(base, 'other');
  await mkdir(root);
  await mkdir(other);
  const source = join(root, `.bosca-${'b'.repeat(32)}.ceol`);
  try {
    await writeFile(source, 'safe');
    await assert.rejects(publish(source, join(other, 'outside.ceol'), root, false), /PATH_NOT_ALLOWED/);
    await writeFile(join(root, 'ordinary.ceol'), 'existing');
    await assert.rejects(publish(join(root, 'ordinary.ceol'), join(root, 'new.ceol'), root, false), /PATH_NOT_ALLOWED/);
    const linkedRoot = join(base, 'linked');
    await symlink(root, linkedRoot, process.platform === 'win32' ? 'junction' : 'dir');
    await assert.rejects(publish(join(linkedRoot, `.bosca-${'b'.repeat(32)}.ceol`), join(linkedRoot, 'new.ceol'), linkedRoot, false), /PATH_NOT_ALLOWED/);
    assert.equal(await readFile(source, 'utf8'), 'safe');
  } finally { await rm(base, { recursive: true }); }
});
