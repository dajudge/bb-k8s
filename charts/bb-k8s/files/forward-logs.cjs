const fs = require('node:fs/promises');
const path = require('node:path');
const { once } = require('node:events');
const { setTimeout: sleep } = require('node:timers/promises');

// bb creates numbered files on rotation and process restart. Track offsets by
// inode so renames do not replay entries, and rescan to discover new files.
function createForwarder(directory, output = process.stdout) {
  const states = new Map();
  let initialScan = true;
  return async function poll() {
    let names;
    try {
      names = await fs.readdir(directory);
    } catch (error) {
      if (error.code === 'ENOENT') {
        initialScan = false;
        return;
      }
      throw error;
    }
    const seen = new Set();
    for (const name of names.sort()) {
      if (!/^(server|host-daemon)(\.\d+|-stdio(?:\.\d+)?)\.log$/.test(name)) continue;
      let file;
      try {
        file = await fs.open(path.join(directory, name), 'r');
        const stat = await file.stat();
        if (!stat.isFile()) continue;
        const key = `${stat.dev}:${stat.ino}`;
        seen.add(key);
        // Skip retained history on sidecar startup. New files are read from
        // byte zero, including lines written before the next directory scan.
        let state = states.get(key);
        if (!state) {
          state = { offset: initialScan ? stat.size : 0, pending: [], skipUntilNewline: false };
          // If startup catches a writer halfway through a retained record,
          // also skip the remainder when it arrives instead of emitting it.
          if (initialScan && stat.size) {
            const lastByte = Buffer.alloc(1);
            await file.read(lastByte, 0, 1, stat.size - 1);
            state.skipUntilNewline = lastByte[0] !== 10;
          }
          states.set(key, state);
        }
        if (stat.size < state.offset) {
          state.offset = 0;
          state.pending = [];
          state.skipUntilNewline = false;
        }
        // Bound each pass so a busy writer cannot starve other files.
        const end = Math.min(stat.size, state.offset + 1024 * 1024);
        const buffer = Buffer.alloc(64 * 1024);
        while (state.offset < end) {
          const { bytesRead } = await file.read(buffer, 0, Math.min(buffer.length, end - state.offset), state.offset);
          if (!bytesRead) break;
          state.offset += bytesRead;
          let chunk = buffer.subarray(0, bytesRead);
          if (state.skipUntilNewline) {
            const firstNewline = chunk.indexOf(10);
            if (firstNewline === -1) continue;
            chunk = chunk.subarray(firstNewline + 1);
            state.skipUntilNewline = false;
          }
          const lastNewline = chunk.lastIndexOf(10);
          if (lastNewline === -1) {
            if (chunk.length) state.pending.push(Buffer.from(chunk));
            continue;
          }
          // Only complete lines may reach shared stdout. Retain a partial
          // record with its inode across read chunks, polls and renames.
          const records = Buffer.concat([...state.pending, chunk.subarray(0, lastNewline + 1)]);
          state.pending = lastNewline + 1 < chunk.length ? [Buffer.from(chunk.subarray(lastNewline + 1))] : [];
          if (!output.write(records)) await once(output, 'drain');
        }
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      } finally {
        await file?.close();
      }
    }
    for (const key of states.keys()) {
      if (!seen.has(key)) states.delete(key);
    }
    initialScan = false;
  };
}

module.exports = { createForwarder };

if (require.main === module) {
  const poll = createForwarder(process.argv[2] || '/var/lib/bb/logs');
  (async () => {
    while (true) {
      await poll();
      await sleep(1000);
    }
  })().catch(error => {
    console.error('bb log forwarding failed:', error);
    process.exitCode = 1;
  });
}
