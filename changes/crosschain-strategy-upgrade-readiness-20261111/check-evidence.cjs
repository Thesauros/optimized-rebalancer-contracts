'use strict';
// Offline consistency check for the release evidence; never accesses a network.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const read = name => JSON.parse(fs.readFileSync(path.join(__dirname, name)));
const target = '62d8a6ffe4c20c7b8545b13ac34d67be6c6e01e7';
const build = read('build-verification.json');
const unit = read('unit-verification.json');
const merged = read('merged-ops-verification.json');
const node22 = read('node22-ops-verification.json');
const companion = read('companion-verification.json');
const forks = [read('base-fork-verification.json'), read('arbitrum-fork-verification.json')];
const fresh = read('base-fresh-payout-verification.json');
for (const item of [build, unit, merged, node22, ...forks, fresh]) assert.equal(item.targetCommit, target);
assert.equal(build.exactDeployedRuntimeRebuilt, true);
assert.equal(build.storageCompatible, true);
assert.equal(build.legacyFields.length, 12);
assert.equal(build.appendedFields.length, 2);
assert.equal(build.inheritedSourcesPreserved.length, 30);
assert.ok(build.targetRuntimeBytes < 24576);
assert.equal(unit.status, 0);
assert.ok(unit.summary.some(line => /188 tests passed, 0 failed, 0 skipped/.test(line)));
assert.equal(merged.mergeConflicts, false);
assert.equal(merged.testStatus, 0);
assert.equal(merged.typecheckStatus, 0);
assert.ok(merged.tests.includes('# pass 66') && merged.tests.includes('# skipped 7') && merged.tests.includes('# fail 0'));
assert.equal(companion.status, 0);
assert.ok(companion.summary.includes('# pass 8'));
assert.match(node22.node, /^v22\./);
assert.equal(node22.syntheticMergeTree, merged.syntheticMergeTree);
assert.equal(node22.testStatus, 0); assert.equal(node22.typecheckStatus, 0); assert.equal(node22.offlineConfigStatus, 0);
assert.equal(node22.network, 'none'); assert.equal(node22.sourceMountedReadOnly, true);
assert.equal(node22.runtimeDependencyLockMatchesCandidate, true);
assert.ok(node22.tests.includes('# pass 65') && node22.tests.includes('# skipped 8') && node22.tests.includes('# fail 0'));
for (const fork of [...forks, fresh]) {
  for (const field of ['snapshotReverted', 'localNodeStopped', 'sourcePinsMatch', 'timeWarpSnapshotsRestoreHead']) assert.equal(fork[field], true);
  assert.equal(fork.liveWrites, false);
  assert.equal(fork.historicalHwmAttested, false);
  assert.deepEqual(fork.before.accruedFeeShares, ['0', '0']);
  assert.equal(fork.before.managementFee, '0'); assert.equal(fork.before.performanceFee, '0');
  assert.equal(fork.before.managementFee, fork.after.managementFee);
  assert.equal(fork.before.performanceFee, fork.after.performanceFee);
  for (const field of ['bareUpgradeFails', 'unauthorizedInitializerFails', 'lowHwmFails', 'repeatedInitializerFails']) assert.equal(fork[field].reverted, true);
  assert.equal(fork.ops.healthyValueMatchesContract, true);
  assert.equal(fork.ops.productionServiceCompatibilityAttested, false);
  assert.equal(fork.ops.faults.length, 2);
  for (const fault of fork.ops.faults) {
    assert.equal(fault.companionContinues, true);
    assert.equal(fault.settlementStillBlocked, true);
    assert.equal(fault.deallocationRevert.error, 'ProviderUnavailable');
    assert.equal(fault.depositRevert.error, 'ProviderUnavailable');
  }
  const recovery = fork.ops.faults.find(item => item.kind === 'empty-provider').timelockedRecovery;
  assert.equal(recovery.delaySeconds, '86400');
  assert.equal(recovery.blockedBeforeEta.error, 'Timelock__StillLocked');
  for (const field of ['exactProviderRemoved', 'entryPreserved', 'pinnedSourceCleared', 'approvalRevoked',
    'completeNavRestored', 'deallocationSimulationPassed', 'localWritesOnly']) assert.equal(recovery[field], true);
  assert.equal(recovery.writtenOffInitialAssets, '0');
  assert.equal(fork.ops.faults.find(item => item.kind === 'funded-provider').entryForceRemovalRejected.error, 'ProviderIsEntry');
  assert.equal(fork.financialPaths.deallocationPassed, true);
  assert.equal(fork.financialPaths.allocationPassed, true);
  assert.equal(fork.financialPaths.zeroResidualIdle, true);
}
const baseline = forks[0].payoutBeforeUpgrade;
assert.equal(baseline.simulation.error, 'TickNotUsable');
assert.equal(baseline.staleOrFrozen, true);
assert.ok(BigInt(baseline.committedAgeSeconds) > BigInt(baseline.instantMaxTickAgeSeconds));
assert.equal(forks[0].financialPaths.instantPayout.operationalGatePreserved, true);
const payout = fresh.financialPaths.instantPayout;
assert.equal(payout.executed, true);
assert.ok(BigInt(payout.assetsPaid) > 0n);
assert.ok(BigInt(payout.remainingCash) < BigInt(payout.allocationFloor));
const proxies = read('proxy-verification.json');
assert.equal(proxies.flatMap(item => item.proxies).length, 6);
for (const item of proxies.flatMap(item => item.proxies)) {
  assert.equal(item.matchesManifest, true);
  if (item.name === 'Strategy') assert.equal(item.implementationRuntimeHash, build.legacyRuntimeHash);
}
const history = read('historical-source-verification.json');
assert.equal(history.find(item => item.network === 'base').deploymentSourcesAttested, true);
const arbitrum = history.find(item => item.network === 'arbitrum');
const configured = read('arbitrum-configured-historical-verification.json');
assert.equal(configured.allMissingSourcesAttested, true);
const sources = { ...arbitrum.sources, ...configured.sources };
assert.equal(Object.keys(sources).length, 5);
assert.ok(Object.values(sources).every(item => item.matches === true));
const gas = read('gas-budget-verification.json');
for (const quote of gas) { assert.equal(quote.targetCommit, target); assert.equal(quote.productionWrites, false); }
const nav = read('live-nav-verification.json');
assert.equal(nav.productionWrites, false);
const summary = { change: 'crosschain-strategy-upgrade-readiness-20261111', targetCommit: target,
  targetRuntimeHash: build.targetRuntimeHash, targetRuntimeBytes: build.targetRuntimeBytes,
  storageCompatible: true, exactLegacyRuntimeRebuilt: true, proxiesAttested: 6,
  deploymentSourcesMatched: 10, evmTestsPassed: 188, companionTestsPassed: 8,
  mergedOpsTestsPassed: 66, existingMergedOpsTestsSkipped: 7, mergedOpsTypecheckPassed: true,
  node22Runtime: { version: node22.node, testsPassed: 65, testsSkipped: 8, typecheckPassed: true, offlineConfigPassed: true,
    runtimeDependencyLockMatchesCandidate: true },
  localMigrationForksPassed: forks.map(item => ({ network: item.network, block: item.forkBlock })),
  freshStatePayout: { block: fresh.forkBlock, assetsUsdc: (Number(payout.assetsPaid) / 1e6).toFixed(6),
    reserveDoesNotBlockPayout: true },
  latestNavObservation: { atUtc: nav.observedAtUtc, tickId: nav.tickId, committedAtUtc: nav.committedAtUtc },
  productionSignable: false, productionImplementationAddresses: { base: null, arbitrum: null },
  historicalHwmAttestations: { base: null, arbitrum: null }, productionServiceReleaseAttested: false,
  releaseVerdict: 'NO-GO: current NAV availability, remote release attestation, migration inputs and Base deployment funding remain open',
  productionWrites: false };
fs.writeFileSync(path.join(__dirname, 'readiness-summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify(summary, null, 2));
