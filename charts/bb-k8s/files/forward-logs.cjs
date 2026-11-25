const fs = require('node:fs/promises');
const path = require('node:path');
const { once } = require('node:events');
const { setTimeout: sleep } = require('node:timers/promises');

// bb creates numbered files on rotation and process restart. Track offsets by
// inode so renames do not replay entries, and rescan to discover new files.
function createForwarder(directory, output = process.stdout) {
  const offsets = new Map();
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
        let offset = offsets.get(key) ?? (initialScan ? stat.size : 0);
        if (stat.size < offset) offset = 0;
        // Bound each pass so a busy writer cannot starve other files.
        const end = Math.min(stat.size, offset + 1024 * 1024);
        const buffer = Buffer.alloc(64 * 1024);
        while (offset < end) {
          const { bytesRead } = await file.read(buffer, 0, Math.min(buffer.length, end - offset), offset);
          if (!bytesRead) break;
          // Copy the bytes: stdout may retain a buffer while it drains.
          if (!output.write(Buffer.from(buffer.subarray(0, bytesRead)))) await once(output, 'drain');
          offset += bytesRead;
        }
        offsets.set(key, offset);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      } finally {
        await file?.close();
      }
    }
    for (const key of offsets.keys()) {
      if (!seen.has(key)) offsets.delete(key);
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
