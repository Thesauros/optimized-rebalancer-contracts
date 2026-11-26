'use strict';
// Freeze the refreshed main in an ignored local checkout; never move a worktree branch.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const target = '62d8a6ffe4c20c7b8545b13ac34d67be6c6e01e7';
const archiveDir = path.join(__dirname, 'baseline-106e905');
if (!fs.existsSync(archiveDir)) {
  fs.mkdirSync(archiveDir);
  for (const file of fs.readdirSync(__dirname).filter(file => file.endsWith('.json'))) {
    fs.copyFileSync(path.join(__dirname, file), path.join(archiveDir, file));
  }
}
const checkout = path.join(root, 'out/strategy-upgrade-readiness-20261111/target-main');
fs.mkdirSync(checkout, { recursive: true });
const tar = cp.execFileSync('git', ['archive', '--format=tar', target], { cwd: root, maxBuffer: 128 * 1024 * 1024 });
cp.execFileSync('tar', ['-x', '-C', checkout], { input: tar });
fs.writeFileSync(path.join(__dirname, 'target-selection.json'), JSON.stringify({
  originalTarget: '106e9059f8fd5e433a2ddd62555a1ede427020a7', targetCommit: target,
  reason: 'Remote main advanced during verification; earlier results archived, refreshed target checked separately.',
  branchesModified: false, productionWrites: false,
  additionalNonProxyChange: 'CctpV2Adapter source changed; existing deployed adapters cannot be updated by proxy implementation replacement.',
}, null, 2) + '\n');
console.log(JSON.stringify({ targetCommit: target, checkout, originalEvidenceArchived: true }));
