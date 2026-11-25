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
  const content = Buffer.from('x\n'.repeat(1024 * 1024) + 'last\n');
  await fs.writeFile(path.join(f.root, 'host-daemon.1.log'), content);
  await poll();
  assert.equal(Buffer.concat(chunks).length, 1024 * 1024);
  await poll();
  await poll();
  assert.deepEqual(Buffer.concat(chunks), content);
});

test('preserves JSON records across the pass limit while forwarding another file', async t => {
  const f = await fixture(t);
  const poll = createForwarder(f.root, f.output);
  await poll();
  const records = Array.from({ length: 10000 }, (_, id) => ({ id, msg: 'x'.repeat(120) }));
  const content = records.map(record => JSON.stringify(record) + '\n').join('');
  assert.ok(Buffer.byteLength(content) > 1024 * 1024);
  await fs.writeFile(path.join(f.root, 'host-daemon.1.log'), content);
  const serverRecord = { server: true };
  await fs.writeFile(path.join(f.root, 'server.1.log'), JSON.stringify(serverRecord) + '\n');
  await poll();
  const firstPass = f.text().trim().split('\n').map(line => JSON.parse(line));
  assert.ok(firstPass.length < records.length + 1);
  assert.deepEqual(firstPass.at(-1), serverRecord);
  await poll();
  const forwarded = f.text().trim().split('\n').map(line => JSON.parse(line));
  assert.equal(forwarded.length, records.length + 1);
  assert.deepEqual(forwarded.filter(record => !record.server), records);
});

test('buffers partial UTF-8 records across polls and rotation without mixing files', async t => {
  const f = await fixture(t);
  const poll = createForwarder(f.root, f.output);
  await poll();
  const file = path.join(f.root, 'host-daemon.1.log');
  const record = Buffer.from(JSON.stringify({ msg: 'hello 🐈' }) + '\n');
  const split = record.indexOf(Buffer.from('🐈')) + 2;
  await fs.writeFile(file, record.subarray(0, split));
  await fs.writeFile(path.join(f.root, 'server.1.log'), '{"server":true}\n');
  await poll();
  assert.equal(f.text(), '{"server":true}\n');
  const rotated = path.join(f.root, 'host-daemon.2.log');
  await fs.rename(file, rotated);
  await fs.appendFile(rotated, record.subarray(split));
  await poll();
  assert.equal(f.text(), '{"server":true}\n' + record.toString());
});

test('discards a buffered partial record when its file is truncated', async t => {
  const f = await fixture(t);
  const poll = createForwarder(f.root, f.output);
  await poll();
  const file = path.join(f.root, 'server.1.log');
  await fs.writeFile(file, '{"msg":"incomplete retained text');
  await poll();
  assert.equal(f.text(), '');
  await fs.writeFile(file, '{"new":true}\n');
  await poll();
  assert.equal(f.text(), '{"new":true}\n');
});

test('skips the continuation of a retained partial record at startup', async t => {
  const f = await fixture(t);
  const file = path.join(f.root, 'server.1.log');
  await fs.writeFile(file, '{"retained":');
  const poll = createForwarder(f.root, f.output);
  await poll();
  await fs.appendFile(file, 'true}\n{"new":true}\n');
  await poll();
  assert.equal(f.text(), '{"new":true}\n');
});

test('accepts a 1 MiB record and drops an oversized record without losing its successor', async t => {
  const f = await fixture(t);
  const poll = createForwarder(f.root, f.output);
  await poll();
  const limit = 1024 * 1024;
  const overhead = Buffer.byteLength(JSON.stringify({ msg: '' }) + '\n');
  const accepted = { msg: 'x'.repeat(limit - overhead) };
  const oversized = { msg: 'x'.repeat(limit - overhead + 1) };
  const successor = { after: true };
  await fs.writeFile(path.join(f.root, 'server.1.log'),
    [accepted, oversized, successor].map(record => JSON.stringify(record) + '\n').join(''));
  await poll();
  await poll();
  await poll();
  const records = f.text().trim().split('\n').map(line => JSON.parse(line));
  assert.equal(records.length, 3);
  assert.deepEqual(records[0], accepted);
  assert.equal(records[1].component, 'log-forwarder');
  assert.equal(records[1].maxRecordBytes, limit);
  assert.deepEqual(records[2], successor);
});

test('discards 80 MiB of newline-free stdio while other files continue and recovers after rotation', async t => {
  const f = await fixture(t);
  const poll = createForwarder(f.root, f.output);
  await poll();
  let stdio = path.join(f.root, 'server-stdio.log');
  const server = path.join(f.root, 'server.1.log');
  const chunk = Buffer.alloc(1024 * 1024, 'x');
  for (let tick = 0; tick < 80; tick++) {
    if (tick === 40) {
      const rotated = path.join(f.root, 'server-stdio.1.log');
      await fs.rename(stdio, rotated);
      await fs.writeFile(stdio, '{"replacement":true}\n');
      stdio = rotated;
    }
    await fs.appendFile(stdio, chunk);
    await fs.appendFile(server, JSON.stringify({ tick }) + '\n');
    await poll();
    // No fragment is ever emitted, and the warning is emitted once, even
    // while the source keeps growing and its inode is renamed.
    const records = f.text().trim().split('\n').map(line => JSON.parse(line));
    assert.deepEqual(records.filter(record => record.tick !== undefined).at(-1), { tick });
    assert.equal(records.filter(record => record.component === 'log-forwarder').length, tick === 0 ? 0 : 1);
  }
  await fs.appendFile(stdio, '\n{"recovered":true}\n');
  await poll();
  const records = f.text().trim().split('\n').map(line => JSON.parse(line));
  assert.equal(records.length, 83);
  assert.deepEqual(records.at(-1), { recovered: true });
});

test('resets oversized-record discard state when the file is truncated', async t => {
  const f = await fixture(t);
  const poll = createForwarder(f.root, f.output);
  await poll();
  const file = path.join(f.root, 'server-stdio.log');
  await fs.writeFile(file, Buffer.alloc(1024 * 1024 + 1, 'x'));
  await poll();
  await poll();
  await fs.writeFile(file, '{"afterTruncation":true}\n');
  await poll();
  const records = f.text().trim().split('\n').map(line => JSON.parse(line));
  assert.equal(records.length, 2);
  assert.equal(records[0].component, 'log-forwarder');
  assert.deepEqual(records[1], { afterTruncation: true });
});
