#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(readFileSync(resolve(repoRoot, "image/package-lock.json"), "utf8"));

const reviewedLicenses = new Set([
  "MIT",
  "ISC",
  "Apache-2.0",
  "BlueOak-1.0.0",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "CC0-1.0",
  "CC-BY-3.0",
  "Artistic-2.0",
  "(MIT OR WTFPL)",
  "(BSD-2-Clause OR MIT OR Apache-2.0)",
]);

// These exact packages omit machine-readable license metadata from the lockfile.
// Their release artifacts/upstream tags were manually reviewed and their notices
// are retained in the image.
const reviewedMetadataExceptions = new Map([
  ["bb-app@0.43.1", "MIT"],
  ["qrcode-terminal@0.12.0", "Apache-2.0"],
]);

const requiredFiles = new Map([
  ["licenses/bb/LICENSE", "d10816aa30183af920bdd789a81b16847bcf3e287e1b3419dd7d85f6e3e8e7b0"],
  ["licenses/codex/LICENSE", "d17f227e4df5da1600391338865ce0f3055211760a36688f816941d58232d8dc"],
  ["licenses/codex/NOTICE", "9d71575ecfd9a843fc1677b0efb08053c6ba9fd686a0de1a6f5382fd3c220915"],
]);

const failures = [];
const counts = new Map();
let packageCount = 0;

for (const [packagePath, metadata] of Object.entries(lock.packages)) {
  if (packagePath === "") continue;

  const name = metadata.name ?? packagePath.split("node_modules/").at(-1);
  const key = `${name}@${metadata.version}`;
  let license = metadata.license;

  if (!license && Array.isArray(metadata.licenses)) {
    license = metadata.licenses.map((item) => item.type).filter(Boolean).join(" OR ");
  }
  license ||= reviewedMetadataExceptions.get(key);

  packageCount += 1;
  if (!license) {
    failures.push(`${key}: missing license metadata and no reviewed exception`);
    continue;
  }
  if (!reviewedLicenses.has(license)) {
    failures.push(`${key}: unreviewed license expression ${JSON.stringify(license)}`);
  }
  counts.set(license, (counts.get(license) ?? 0) + 1);
}

for (const [relativePath, expectedHash] of requiredFiles) {
  const contents = readFileSync(resolve(repoRoot, relativePath));
  const actualHash = createHash("sha256").update(contents).digest("hex");
  if (actualHash !== expectedHash) {
    failures.push(`${relativePath}: expected SHA-256 ${expectedHash}, got ${actualHash}`);
  }
}

if (failures.length > 0) {
  console.error("License verification failed:\n");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(`Reviewed ${packageCount} locked production package paths:`);
for (const [license, count] of [...counts].sort(([a], [b]) => a.localeCompare(b))) {
  console.log(`- ${license}: ${count}`);
}
console.log("Required direct-component license and NOTICE checksums match.");
