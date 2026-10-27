/**
 * Upgrade the live vault proxies to a freshly built Rebalancer implementation.
 *
 * Written for the MAX_PERFORMANCE_FEE cap raise (0.2e18 -> 0.25e18) in
 * contracts/libraries/Constants.sol, but the gates are generic: the run aborts
 * unless the new build differs from the build recorded for the live
 * implementation in exactly the files listed in ALLOWED_SOURCE_DIFFS.
 *
 * Usage (read-only; no private key, no transactions):
 *   npx hardhat run scripts/upgrade-vault-implementation.ts --network base
 *   npx hardhat run scripts/upgrade-vault-implementation.ts --network arbitrum
 *
 * Usage (deploys the implementation, then sends ProxyAdmin.upgradeAndCall):
 *   DRY_RUN=0 npx hardhat run scripts/upgrade-vault-implementation.ts --network base
 *
 * DRY_RUN is the default: anything other than DRY_RUN=0 prints the plan and stops.
 *
 * Prerequisite SEC-001 (Critical, open): the ProxyAdmin of every live vault is owned
 * by the deployer EOA, so one key can swap the code holding user funds with no delay
 * and no multisig. Ownership must move to the governance Safe first. The execute path
 * therefore sends the upgrade only when the configured signer is the current
 * ProxyAdmin owner; once ownership has moved to the Safe it prints the exact calldata
 * for the Safe to execute and stops.
 *
 * Optional env:
 *   DRY_RUN            '0' to execute. Default: dry run.
 *   IMPL_RECORD_NAME   hardhat-deploy record name for the new implementation.
 *                      Default: USDCRebalancerImplementationV2. The existing
 *                      USDCRebalancerImplementation record is left untouched so the
 *                      old build stays diffable.
 *   SKIP_VERIFY        '1' to skip block-explorer verification after deploy.
 *   VAULT              override the vault proxy address instead of reading
 *                      deployments/<network>/USDCRebalancerProxy.json.
 */
import hre, { ethers } from 'hardhat';
import type { Contract, InterfaceAbi } from 'ethers';
import fs from 'fs';
import path from 'path';

const ERC1967_IMPLEMENTATION_SLOT =
  '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const ERC1967_ADMIN_SLOT =
  '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';

/** Governance Safe that must own every ProxyAdmin before this upgrade runs (SEC-001). */
const GOVERNANCE_SAFE = '0x3CDD947001afBa4C334D49125fd4bac3E4a3bfF1';
/** Deployer EOA that owns every live ProxyAdmin as of 2026-09-21 (SEC-001). */
const LEGACY_DEPLOYER_EOA = '0xafA9ed53c33bbD8DE300481ce150dB3D35738F9D';
const EXECUTOR_TARGET = '0x48aee620254556dfa676d9ceb0B2f2a19B6469c5';

const ADMIN_ROLE = ethers.ZeroHash;
const EXECUTOR_ROLE = ethers.id('EXECUTOR_ROLE');

/** Ethereum mainnet runs the legacy generation and is deliberately out of scope. */
const MAINNET_CHAIN_ID = 1n;

/**
 * Source files this upgrade is allowed to change, relative to the repo root and
 * matched against the compiler input. Anything else aborts the run: an upgrade of a
 * proxy holding user funds must not smuggle in unrelated logic.
 */
const ALLOWED_SOURCE_DIFFS = new Set(['contracts/libraries/Constants.sol']);

/** Constant whose value is the whole point of this upgrade; asserted explicitly. */
const EXPECTED_NEW_CAP_LINE =
  'uint256 constant MAX_PERFORMANCE_FEE = 0.25 * 1e18; // 25%';
const EXPECTED_OLD_CAP_LINE =
  'uint256 constant MAX_PERFORMANCE_FEE = 0.2 * 1e18; // 20%';

const PROXY_ADMIN_ABI = [
  'function owner() view returns (address)',
  'function UPGRADE_INTERFACE_VERSION() view returns (string)',
  'function upgradeAndCall(address proxy, address implementation, bytes data) payable',
  'function transferOwnership(address newOwner)',
];

const OWNABLE_ABI = [
  'function owner() view returns (address)',
  'function pendingOwner() view returns (address)',
];

const VAULT_ABI = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function asset() view returns (address)',
  'function decimals() view returns (uint8)',
  'function totalAssets() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function getTimelock() view returns (address)',
  'function getTreasury() view returns (address)',
  'function getManagementFee() view returns (uint96)',
  'function getPerformanceFee() view returns (uint96)',
  'function getMinAssets() view returns (uint256)',
  'function getEntryProvider() view returns (address)',
  'function getProviders() view returns (address[])',
  'function getLastTotalAssets() view returns (uint256)',
  'function getLastTimestamp() view returns (uint64)',
  'function paused(uint8) view returns (bool)',
  'function hasRole(bytes32,address) view returns (bool)',
  'function setPerformanceFee(uint96)',
  'function version() view returns (string)',
  'function initializeV2()',
];

interface DeploymentRecord {
  address: string;
  abi: unknown[];
  args?: unknown[];
  transactionHash?: string;
  deployedBytecode?: string;
  metadata?: string;
  storageLayout?: unknown;
}

function readRecord(name: string): DeploymentRecord | null {
  const file = path.join(
    hre.config.paths.deployments,
    hre.network.name,
    `${name}.json`,
  );
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8')) as DeploymentRecord;
}

function slotToAddress(slot: string): string {
  return ethers.getAddress(`0x${slot.slice(-40)}`);
}

/** Every zero-arg view whose value must survive the upgrade byte-for-byte. */
async function snapshotVault(
  vault: Contract,
  proxyAddress: string,
): Promise<Record<string, string>> {
  const [
    name,
    symbol,
    asset,
    decimals,
    totalAssets,
    totalSupply,
    deadShares,
    timelock,
    treasury,
    managementFee,
    performanceFee,
    minAssets,
    entryProvider,
    providers,
    lastTotalAssets,
    lastTimestamp,
    depositPaused,
    withdrawPaused,
    safeIsAdmin,
    executorHasRole,
  ] = await Promise.all([
    vault.name(),
    vault.symbol(),
    vault.asset(),
    vault.decimals(),
    vault.totalAssets(),
    vault.totalSupply(),
    vault.balanceOf(proxyAddress),
    vault.getTimelock(),
    vault.getTreasury(),
    vault.getManagementFee(),
    vault.getPerformanceFee(),
    vault.getMinAssets(),
    vault.getEntryProvider(),
    vault.getProviders(),
    vault.getLastTotalAssets(),
    vault.getLastTimestamp(),
    vault.paused(0),
    vault.paused(1),
    vault.hasRole(ADMIN_ROLE, GOVERNANCE_SAFE),
    vault.hasRole(EXECUTOR_ROLE, EXECUTOR_TARGET),
  ]);

  return {
    name: String(name),
    symbol: String(symbol),
    asset,
    decimals: String(decimals),
    totalAssets: totalAssets.toString(),
    totalSupply: totalSupply.toString(),
    deadShares: deadShares.toString(),
    timelock,
    treasury,
    managementFee: managementFee.toString(),
    performanceFee: performanceFee.toString(),
    minAssets: minAssets.toString(),
    entryProvider,
    providers: (providers as string[]).join(','),
    lastTotalAssets: lastTotalAssets.toString(),
    lastTimestamp: lastTimestamp.toString(),
    depositPaused: String(depositPaused),
    withdrawPaused: String(withdrawPaused),
    safeHasAdminRole: String(safeIsAdmin),
    executorHasRole: String(executorHasRole),
  };
}

function printSnapshot(label: string, snap: Record<string, string>) {
  console.log(`\n=== ${label} ===`);
  for (const [k, v] of Object.entries(snap)) {
    console.log(`  ${k.padEnd(20)} ${v}`);
  }
}

/** Selectors that exist in the live ABI and must still exist afterwards. */
function abiSignatures(abi: unknown[]): Set<string> {
  const iface = new ethers.Interface(abi as InterfaceAbi);
  const out = new Set<string>();
  iface.forEachFunction((f) => out.add(f.format('full') as string));
  return out;
}

/**
 * ERC-7201 namespace slots. All Rebalancer state lives behind these three slots, so
 * if none of them moves and no plain storage variable is added, the upgrade cannot
 * collide with existing state.
 */
function extractNamespaceSlots(
  sources: Record<string, { content?: string }>,
): Map<string, string> {
  const out = new Map<string, string>();
  for (const [file, entry] of Object.entries(sources)) {
    const content = entry?.content;
    if (!content) continue;
    const re = /bytes32\s+(?:private|internal|public)?\s*constant\s+(\w*StorageLocation)\s*=\s*(0x[0-9a-fA-F]{64})/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(content)) !== null) {
      out.set(`${file}:${m[1]}`, m[2].toLowerCase());
    }
  }
  return out;
}

async function main() {
  const dryRun = process.env.DRY_RUN !== '0';
  const implRecordName = process.env.IMPL_RECORD_NAME ?? 'USDCRebalancerImplementationV2';

  const network = await ethers.provider.getNetwork();
  const chainId = network.chainId;

  console.log(`network:  ${hre.network.name} (chainId ${chainId})`);
  console.log(`mode:     ${dryRun ? 'DRY RUN (read-only, nothing is sent)' : 'EXECUTE'}`);
  console.log(`record:   new implementation will be stored as ${implRecordName}`);
  console.log(`safe:     ${GOVERNANCE_SAFE} (SEC-001 target owner for every ProxyAdmin)`);

  if (chainId === MAINNET_CHAIN_ID) {
    throw new Error(
      'Ethereum mainnet hosts the legacy vault generation (solc 0.8.23, no current getters). ' +
        'It is out of scope for this upgrade - see audit/scope-2026-09-fee-cap-25.md.',
    );
  }

  /*//////////////////////////////////////////////////////////////
                     1. LOCATE THE LIVE STACK
  //////////////////////////////////////////////////////////////*/

  const proxyRecord = readRecord('USDCRebalancerProxy');
  const implRecord = readRecord('USDCRebalancerImplementation');
  if (!proxyRecord) {
    throw new Error(
      `no USDCRebalancerProxy record for ${hre.network.name} - run with VAULT=<proxy> or deploy first`,
    );
  }
  if (!implRecord) {
    throw new Error(
      `no USDCRebalancerImplementation record for ${hre.network.name} - cannot diff against the live build`,
    );
  }

  const proxyAddress = process.env.VAULT ?? proxyRecord.address;
  const recordedImpl = implRecord.address;

  const proxyCode = await ethers.provider.getCode(proxyAddress);
  if (proxyCode === '0x') {
    throw new Error(`${proxyAddress} has no code on ${hre.network.name} - wrong address or wrong RPC`);
  }

  const onChainImpl = slotToAddress(
    await ethers.provider.getStorage(proxyAddress, ERC1967_IMPLEMENTATION_SLOT),
  );
  const proxyAdmin = slotToAddress(
    await ethers.provider.getStorage(proxyAddress, ERC1967_ADMIN_SLOT),
  );

  // The proxy constructor deploys the ProxyAdmin at its own nonce 1; agree with the
  // on-chain admin slot before trusting either.
  const derivedProxyAdmin = ethers.getCreateAddress({ from: proxyAddress, nonce: 1 });
  if (derivedProxyAdmin.toLowerCase() !== proxyAdmin.toLowerCase()) {
    throw new Error(
      `ProxyAdmin mismatch: admin slot says ${proxyAdmin}, CREATE at nonce 1 says ${derivedProxyAdmin}`,
    );
  }

  const proxyAdminContract = new ethers.Contract(proxyAdmin, PROXY_ADMIN_ABI, ethers.provider);
  const proxyAdminOwner = await proxyAdminContract.owner();
  const upgradeInterfaceVersion = await proxyAdminContract
    .UPGRADE_INTERFACE_VERSION()
    .catch(() => '(missing - pre-5.0.0 ProxyAdmin)');

  console.log('\n=== live stack (read from chain) ===');
  console.log(`  vault proxy           ${proxyAddress}`);
  console.log(`  implementation (slot) ${onChainImpl}`);
  console.log(`  implementation (rec.) ${recordedImpl}`);
  if (onChainImpl.toLowerCase() !== recordedImpl.toLowerCase()) {
    throw new Error(
      'recorded implementation does not match the ERC-1967 slot - the deployment record is stale',
    );
  }
  console.log(`  ProxyAdmin            ${proxyAdmin}`);
  console.log(`  ProxyAdmin.owner()    ${proxyAdminOwner}`);
  console.log(`  UPGRADE_INTERFACE_VERSION ${upgradeInterfaceVersion}`);
  if (upgradeInterfaceVersion !== '5.0.0') {
    throw new Error(
      `expected ProxyAdmin UPGRADE_INTERFACE_VERSION 5.0.0 (upgradeAndCall only), got ${upgradeInterfaceVersion}`,
    );
  }

  const sec001Open =
    proxyAdminOwner.toLowerCase() === LEGACY_DEPLOYER_EOA.toLowerCase();
  const sec001Fixed =
    proxyAdminOwner.toLowerCase() === GOVERNANCE_SAFE.toLowerCase();
  console.log(
    `  SEC-001               ${
      sec001Fixed
        ? 'remediated (ProxyAdmin owned by the governance Safe)'
        : sec001Open
          ? 'OPEN (ProxyAdmin owned by the deployer EOA) - transfer ownership to the Safe first'
          : `UNEXPECTED owner ${proxyAdminOwner} - inspect before proceeding`
    }`,
  );

  const safeCodeSize = (await ethers.provider.getCode(GOVERNANCE_SAFE)).length;
  console.log(
    `  Safe code on chain    ${
      safeCodeSize > 2
        ? `present (${(safeCodeSize - 2) / 2} bytes)`
        : 'ABSENT - SEC-019: the Safe has no code on this chain, so it cannot own the ProxyAdmin or hold ADMIN_ROLE here yet'
    }`,
  );

  const vault = new ethers.Contract(proxyAddress, VAULT_ABI, ethers.provider);
  const before = await snapshotVault(vault, proxyAddress);
  printSnapshot('vault state before upgrade', before);

  const timelockOwnable = new ethers.Contract(
    before.timelock,
    OWNABLE_ABI,
    ethers.provider,
  );
  console.log(
    `\n  Timelock.owner()      ${await timelockOwnable.owner().catch(() => '(not Ownable2Step)')}`,
  );

  /*//////////////////////////////////////////////////////////////
                2. BUILD THE NEW IMPLEMENTATION LOCALLY
  //////////////////////////////////////////////////////////////*/

  await hre.run('compile', { quiet: true });
  const artifact = await hre.artifacts.readArtifact('Rebalancer');
  const buildInfo = await hre.artifacts.getBuildInfo(
    'contracts/Rebalancer.sol:Rebalancer',
  );
  if (!buildInfo) {
    throw new Error('no build info for contracts/Rebalancer.sol:Rebalancer');
  }
  const newSources = buildInfo.input.sources as Record<string, { content?: string }>;
  const newOutput = (
    buildInfo.output as unknown as {
      contracts: Record<string, Record<string, { storageLayout: unknown }>>;
    }
  ).contracts['contracts/Rebalancer.sol'].Rebalancer;

  console.log('\n=== new build ===');
  console.log(`  solc                  ${buildInfo.solcLongVersion}`);
  console.log(
    `  evmVersion            ${buildInfo.input.settings?.evmVersion ?? '(compiler default)'}`,
  );
  console.log(
    `  optimizer             ${JSON.stringify(buildInfo.input.settings?.optimizer)}`,
  );
  console.log(`  deployedBytecode      keccak256 ${ethers.keccak256(artifact.deployedBytecode)}`);

  const oldMetadata = JSON.parse(implRecord.metadata ?? '{}') as {
    compiler?: { version?: string };
    settings?: { optimizer?: unknown; evmVersion?: string };
    sources?: Record<string, { content?: string }>;
  };
  console.log('\n=== live build (from deployments record) ===');
  console.log(`  solc                  ${oldMetadata.compiler?.version}`);
  console.log(`  evmVersion            ${oldMetadata.settings?.evmVersion}`);
  console.log(`  optimizer             ${JSON.stringify(oldMetadata.settings?.optimizer)}`);
  console.log(
    `  deployedBytecode      keccak256 ${ethers.keccak256(implRecord.deployedBytecode ?? '0x')}`,
  );

  const onChainCode = await ethers.provider.getCode(onChainImpl);
  console.log(
    `  on-chain runtime code keccak256 ${ethers.keccak256(onChainCode)}`,
  );
  if (
    ethers.keccak256(onChainCode).toLowerCase() !==
    ethers.keccak256(implRecord.deployedBytecode ?? '0x').toLowerCase()
  ) {
    throw new Error(
      'the recorded implementation bytecode does not match the code on chain - stop and reconcile',
    );
  }
  console.log('  => the live implementation is exactly the recorded build');

  if (oldMetadata.settings?.evmVersion !== buildInfo.input.settings?.evmVersion) {
    console.log(
      `\n  !! evmVersion differs (${oldMetadata.settings?.evmVersion} -> ${buildInfo.input.settings?.evmVersion}). ` +
        'Hardhat targets paris for this repo; keep it that way so the new build stays comparable to the live one.',
    );
  }

  /*//////////////////////////////////////////////////////////////
             3. STORAGE-LAYOUT / SOURCE COMPATIBILITY GATES
  //////////////////////////////////////////////////////////////*/

  console.log('\n=== storage layout compatibility ===');
  const oldLayout = JSON.stringify(implRecord.storageLayout ?? null);
  const newLayout = JSON.stringify(newOutput.storageLayout ?? null);
  const oldEntries =
    ((implRecord.storageLayout as { storage?: unknown[] })?.storage ?? []).length;
  const newEntries =
    ((newOutput.storageLayout as { storage?: unknown[] })?.storage ?? []).length;
  console.log(
    `  plain storage slots   live=${oldEntries}  new=${newEntries}` +
      '  (all vault state is ERC-7201 namespaced, so this list is empty by design)',
  );
  console.log(`  layout identical:     ${oldLayout === newLayout}`);
  if (oldLayout !== newLayout) {
    throw new Error('storage layout changed - this upgrade is not storage-compatible');
  }

  const oldSlots = extractNamespaceSlots(oldMetadata.sources ?? {});
  const newSlots = extractNamespaceSlots(newSources);
  console.log('  ERC-7201 namespace slots (must be byte-identical):');
  let slotsOk = oldSlots.size === newSlots.size && newSlots.size > 0;
  for (const [k, v] of newSlots) {
    const prev = oldSlots.get(k);
    const same = prev === v;
    slotsOk = slotsOk && same;
    console.log(`    ${same ? 'ok  ' : 'DIFF'} ${k} = ${v}`);
  }
  if (!slotsOk) {
    throw new Error('an ERC-7201 namespace slot moved or disappeared - aborting');
  }

  // Scoped to the Rebalancer compilation unit: buildInfo.input.sources is the import
  // graph of contracts/Rebalancer.sol, which is exactly the set of sources whose
  // content can change the implementation bytecode. Files outside that graph
  // (Timelock.sol, the provider adapters, VaultFactory.sol) cannot affect this
  // upgrade and are compared by the ABI check instead.
  console.log('\n=== source diff vs the live build (Rebalancer compilation unit) ===');
  const oldSrc = oldMetadata.sources ?? {};
  const allKeys = new Set([...Object.keys(oldSrc), ...Object.keys(newSources)]);
  const changed: string[] = [];
  for (const key of [...allKeys].sort()) {
    const a = oldSrc[key]?.content;
    const b = newSources[key]?.content;
    if (a === b) continue;
    changed.push(key);
    const status = a === undefined ? 'ADDED  ' : b === undefined ? 'REMOVED' : 'CHANGED';
    console.log(`  ${status} ${key}`);
  }
  if (changed.length === 0) {
    throw new Error(
      'the new build is source-identical to the live implementation - there is nothing to upgrade',
    );
  }
  const disallowed = changed.filter((f) => !ALLOWED_SOURCE_DIFFS.has(f));
  if (disallowed.length > 0) {
    throw new Error(
      `source changed outside the allowed set [${[...ALLOWED_SOURCE_DIFFS].join(', ')}]: ${disallowed.join(', ')}. ` +
        'A proxy holding user funds must not be upgraded with unrelated logic changes.',
    );
  }

  const oldCap = (oldSrc['contracts/libraries/Constants.sol']?.content ?? '')
    .split('\n')
    .find((l) => l.includes('MAX_PERFORMANCE_FEE'))
    ?.trim();
  const newCap = (newSources['contracts/libraries/Constants.sol']?.content ?? '')
    .split('\n')
    .find((l) => l.includes('MAX_PERFORMANCE_FEE'))
    ?.trim();
  console.log(`\n  contracts/libraries/Constants.sol`);
  console.log(`    live: ${oldCap}`);
  console.log(`    new:  ${newCap}`);
  if (oldCap !== EXPECTED_OLD_CAP_LINE || newCap !== EXPECTED_NEW_CAP_LINE) {
    throw new Error(
      `unexpected cap lines. expected live="${EXPECTED_OLD_CAP_LINE}" new="${EXPECTED_NEW_CAP_LINE}"`,
    );
  }
  const oldMgmt = (oldSrc['contracts/libraries/Constants.sol']?.content ?? '').includes(
    'uint256 constant MAX_MANAGEMENT_FEE = 0.05 * 1e18;',
  );
  const newMgmt = (newSources['contracts/libraries/Constants.sol']?.content ?? '').includes(
    'uint256 constant MAX_MANAGEMENT_FEE = 0.05 * 1e18;',
  );
  if (!oldMgmt || !newMgmt) {
    throw new Error('MAX_MANAGEMENT_FEE moved - this upgrade must leave the 5% management cap alone');
  }
  console.log('    MAX_MANAGEMENT_FEE unchanged at 0.05e18 (5%)');

  console.log('\n=== ABI compatibility ===');
  const oldSigs = abiSignatures(implRecord.abi);
  const newSigs = abiSignatures(artifact.abi);
  const removed = [...oldSigs].filter((s) => !newSigs.has(s));
  const added = [...newSigs].filter((s) => !oldSigs.has(s));
  console.log(`  live selectors: ${oldSigs.size}   new selectors: ${newSigs.size}`);
  console.log(`  removed: ${removed.length === 0 ? 'none' : removed.join(', ')}`);
  console.log(`  added:   ${added.length === 0 ? 'none' : added.join(', ')}`);
  if (removed.length > 0) {
    throw new Error(`the new ABI drops selectors integrations may call: ${removed.join(', ')}`);
  }

  console.log('\n=== upgrade markers ===');
  console.log(
    `  version()      ${newSigs.has('version() view returns (string)') ? 'present' : 'ABSENT - this generation has no version getter'}`,
  );
  console.log(
    `  initializeV2() ${newSigs.has('initializeV2()') ? 'present' : 'ABSENT - no reinitializer, so upgradeAndCall data must be 0x'}`,
  );
  if (newSigs.has('initializeV2()')) {
    throw new Error(
      'initializeV2() exists in the new build: upgradeAndCall must pass its calldata, ' +
        'which this script does not do. Extend the script deliberately.',
    );
  }

  /*//////////////////////////////////////////////////////////////
                      4. THE UPGRADE CALL
  //////////////////////////////////////////////////////////////*/

  const upgradeData = '0x';
  const adminIface = new ethers.Interface(PROXY_ADMIN_ABI);
  const buildUpgradeCalldata = (implementation: string) =>
    adminIface.encodeFunctionData('upgradeAndCall', [
      proxyAddress,
      implementation,
      upgradeData,
    ]);

  // The implementation address is unknown until it is deployed, so the dry-run
  // template is encoded against the zero address: word 2 of the calldata
  // (hex chars 74..138, i.e. the second 32-byte word) is the only thing to replace.
  const templateCalldata = buildUpgradeCalldata(ethers.ZeroAddress);

  console.log('\n=== upgrade plan ===');
  console.log(`  1. deploy Rebalancer (no constructor args) -> new implementation`);
  console.log(`  2. assert keccak256(runtime code) == ${ethers.keccak256(artifact.deployedBytecode)}`);
  console.log(`  3. ProxyAdmin(${proxyAdmin}).upgradeAndCall(`);
  console.log(`       proxy         = ${proxyAddress},`);
  console.log(`       implementation= <NEW_IMPLEMENTATION>,`);
  console.log(`       data          = ${upgradeData}`);
  console.log(`     )   [payable, onlyOwner, msg.value must be 0]`);
  console.log(`  4. re-read the ERC-1967 implementation slot and the getter snapshot`);
  console.log(`\n  calldata template (word 2, hex chars 74..138, is the implementation address):`);
  console.log(`    to=${proxyAdmin}`);
  console.log(`    data=${templateCalldata}`);
  console.log(`    value=0`);
  console.log(`  re-run with DRY_RUN=0 to deploy and print the final, substituted calldata.`);

  if (dryRun) {
    console.log('\nDRY RUN: nothing deployed, nothing sent. Re-run with DRY_RUN=0 to execute.');
    printPostUpgradePlan(before);
    return;
  }

  /*//////////////////////////////////////////////////////////////
                        5. EXECUTE
  //////////////////////////////////////////////////////////////*/

  if (!process.env.DEPLOYER_PRIVATE_KEY) {
    throw new Error('DRY_RUN=0 requires DEPLOYER_PRIVATE_KEY');
  }
  const { deploy, log, get } = hre.deployments;
  const named = await hre.getNamedAccounts();
  const deployer = named.deployer ?? (await ethers.getSigners())[0].address;

  const existing = await get(implRecordName);
  let newImpl: string;

  if (existing) {
    newImpl = existing.address;
    log(`reusing ${implRecordName} at ${newImpl}`);
  } else {
    const deployed = await deploy(implRecordName, {
      contract: 'Rebalancer',
      from: deployer,
      args: [],
      log: true,
      waitConfirmations: 2,
    });
    newImpl = deployed.address;
  }

  const deployedCode = await ethers.provider.getCode(newImpl);
  const deployedHash = ethers.keccak256(deployedCode);
  console.log(`\n  new implementation    ${newImpl}`);
  console.log(`  runtime code keccak   ${deployedHash}`);
  if (deployedHash.toLowerCase() !== ethers.keccak256(artifact.deployedBytecode).toLowerCase()) {
    throw new Error(
      `deployed runtime code ${deployedHash} != local artifact ${ethers.keccak256(artifact.deployedBytecode)} - not upgrading`,
    );
  }
  console.log('  matches the local build: yes');

  if (process.env.SKIP_VERIFY !== '1' && process.env.ETHERSCAN_API_KEY) {
    const { verify } = await import('../utils/verify');
    await verify(newImpl, []);
  }

  const finalCalldata = buildUpgradeCalldata(newImpl);
  console.log('\n=== executable upgrade transaction ===');
  console.log(`  to=${proxyAdmin}`);
  console.log(`  data=${finalCalldata}`);
  console.log(`  value=0`);

  const [signer] = await ethers.getSigners();
  const signerAddress = await signer.getAddress();
  if (proxyAdminOwner.toLowerCase() !== signerAddress.toLowerCase()) {
    console.log(
      `\n  ProxyAdmin.owner() is ${proxyAdminOwner}, not the configured signer ${signerAddress}.`,
    );
    console.log(
      `  The new implementation at ${newImpl} is deployed and inert; the upgrade itself must be sent by the owner.`,
    );
    if (proxyAdminOwner.toLowerCase() === GOVERNANCE_SAFE.toLowerCase()) {
      console.log('  Submit the transaction above from the governance Safe (single contract interaction, value 0).');
    } else if (sec001Open) {
      console.log(
        `  SEC-001 is still open: ownership sits with the deployer EOA. Transfer it to ${GOVERNANCE_SAFE} first,` +
          ' then re-run this script in dry-run mode to confirm before upgrading.',
      );
      console.log(`    ProxyAdmin.transferOwnership calldata:`);
      console.log(
        `      to=${proxyAdmin} data=${adminIface.encodeFunctionData('transferOwnership', [GOVERNANCE_SAFE])}`,
      );
    }
    console.log('\nStopping: the implementation is deployed, the upgrade was NOT sent.');
    return;
  }

  const adminAsSigner = new ethers.Contract(proxyAdmin, PROXY_ADMIN_ABI, signer);
  const tx = await adminAsSigner.upgradeAndCall(proxyAddress, newImpl, upgradeData, {
    value: 0n,
  });
  console.log(`\n  upgradeAndCall tx: ${tx.hash}`);
  const receipt = await tx.wait(2);
  console.log(`  confirmed in block ${receipt?.blockNumber}, status ${receipt?.status}`);

  /*//////////////////////////////////////////////////////////////
                  6. POST-UPGRADE VERIFICATION
  //////////////////////////////////////////////////////////////*/

  const slotAfter = slotToAddress(
    await ethers.provider.getStorage(proxyAddress, ERC1967_IMPLEMENTATION_SLOT),
  );
  console.log(`\n=== post-upgrade verification ===`);
  console.log(`  ERC-1967 implementation slot: ${slotAfter}`);
  if (slotAfter.toLowerCase() !== newImpl.toLowerCase()) {
    throw new Error(`implementation slot is ${slotAfter}, expected ${newImpl}`);
  }
  console.log('  slot points at the new implementation: yes');
  console.log(
    `  admin slot unchanged: ${
      slotToAddress(await ethers.provider.getStorage(proxyAddress, ERC1967_ADMIN_SLOT)) ===
      proxyAdmin
    }`,
  );

  const after = await snapshotVault(vault, proxyAddress);
  printSnapshot('vault state after upgrade', after);

  const drift = Object.keys(before).filter((k) => before[k] !== after[k]);
  // lastTimestamp moves whenever applyFees ran during the interval; totalAssets/
  // totalSupply move with market yield. Everything else must be identical.
  const tolerated = new Set(['lastTimestamp', 'totalAssets', 'totalSupply', 'deadShares']);
  const unexpected = drift.filter((k) => !tolerated.has(k));
  console.log(
    `\n  changed fields: ${drift.length === 0 ? 'none' : drift.join(', ')}`,
  );
  if (unexpected.length > 0) {
    throw new Error(`unexpected post-upgrade drift in: ${unexpected.join(', ')}`);
  }
  console.log('  no unexpected drift: yes');

  console.log(
    `\n  getPerformanceFee()   ${after.performanceFee} (unchanged by the upgrade; the cap change only widens what setPerformanceFee may be given)`,
  );
  console.log(`  getManagementFee()    ${after.managementFee}`);
  console.log(`  getTimelock()         ${after.timelock}`);
  console.log(
    `  version()/initializeV2() absent in this generation, so the ERC-1967 slot plus this snapshot is the proof of upgrade`,
  );

  printPostUpgradePlan(after);
}

/**
 * The cap itself is a compile-time constant with no getter, so no unauthenticated
 * call can distinguish a 20% build from a 25% one: setPerformanceFee checks the role
 * before the cap, and both builds revert Unauthorized() for a stranger. Observing the
 * new cap requires an authenticated call from the ADMIN_ROLE holder. This is printed,
 * never sent.
 */
function printPostUpgradePlan(snap: Record<string, string>) {
  const iface = new ethers.Interface(VAULT_ABI);
  console.log('\n=== optional authenticated capability probe (manual, not sent here) ===');
  console.log(
    `  From the ADMIN_ROLE holder (${GOVERNANCE_SAFE}), on the vault proxy, to observe the new cap directly:`,
  );
  console.log(
    `    setPerformanceFee(0.25e18)  data=${iface.encodeFunctionData('setPerformanceFee', [
      250_000_000_000_000_000n,
    ])}`,
  );
  console.log(
    `    then setPerformanceFee(${snap.performanceFee}) to restore  data=${iface.encodeFunctionData('setPerformanceFee', [
      BigInt(snap.performanceFee),
    ])}`,
  );
  console.log(
    '  Both calls mint any accrued fee to the treasury first (setPerformanceFee calls _applyFees),',
  );
  console.log(
    '  and both emit events, so treat this as a live governance action, not a read.',
  );
  console.log(
    `  On Plasma and Monad it is not executable at all until SEC-019 is closed (the Safe has no code there).`,
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
