const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Writable } = require('node:stream');
const { createForwarder } = require('../charts/bb-k8s/files/forward-logs.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'bb-log-forwarder-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  let text = '';
  const output = new Writable({ write(chunk, encoding, done) { text += chunk.toString(); done(); } });
  return { root, output, text: () => text };
}

test('forwards structured and stdio writes without replaying retained history', async t => {
  const f = await fixture(t);
  const names = ['server.1.log', 'host-daemon.2.log', 'server-stdio.log', 'host-daemon-stdio.log'];
  for (const name of names) await fs.writeFile(path.join(f.root, name), 'old\n');
  const poll = createForwarder(f.root, f.output);
  await poll();
  assert.equal(f.text(), '');
  for (const name of names) await fs.appendFile(path.join(f.root, name), `${name}\n`);
  await fs.writeFile(path.join(f.root, 'unrelated.log'), 'ignore\n');
  await poll();
  assert.deepEqual(f.text().trim().split('\n').sort(), names.sort());
  await poll();
  assert.equal(f.text().trim().split('\n').length, 4);
});

test('discovers new files, follows inode renames, and reads a replacement from byte zero', async t => {
  const f = await fixture(t);
  const poll = createForwarder(f.root, f.output);
  await poll();
  await fs.writeFile(path.join(f.root, 'server.1.log'), 'first\n');
  await poll();
  await fs.rename(path.join(f.root, 'server.1.log'), path.join(f.root, 'server.2.log'));
  await fs.appendFile(path.join(f.root, 'server.2.log'), 'after-rename\n');
  await fs.writeFile(path.join(f.root, 'server.1.log'), 'replacement\n');
  await poll();
  assert.deepEqual(f.text().trim().split('\n').sort(), ['first', 'after-rename', 'replacement'].sort());
  await fs.unlink(path.join(f.root, 'server.2.log'));
  await poll();
  assert.equal(f.text().trim().split('\n').length, 3);
});

test('handles missing directories and files truncated in place', async t => {
  const f = await fixture(t);
  const directory = path.join(f.root, 'logs');
  const poll = createForwarder(directory, f.output);
  await poll();
  await fs.mkdir(directory);
  const name = path.join(directory, 'server-stdio.log');
  await fs.writeFile(name, 'first-long-line\n');
  await poll();
  await fs.writeFile(name, 'short\n');
  await poll();
  assert.equal(f.text(), 'first-long-line\nshort\n');
});

test('honors stdout backpressure and bounds bytes read per pass', async t => {
  const f = await fixture(t);
  const chunks = [];
  const output = new Writable({
    highWaterMark: 1,
    write(chunk, encoding, done) { chunks.push(Buffer.from(chunk)); setImmediate(done); }
  });
  const poll = createForwarder(f.root, output);
  await poll();
  const content = Buffer.alloc(2 * 1024 * 1024 + 13, 'x');
  await fs.writeFile(path.join(f.root, 'host-daemon.1.log'), content);
  await poll();
  assert.equal(Buffer.concat(chunks).length, 1024 * 1024);
  await poll();
  await poll();
  assert.deepEqual(Buffer.concat(chunks), content);
});
