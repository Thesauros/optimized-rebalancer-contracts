/**
 * Phase 1: deploy the cross-chain contracts on the connected network.
 *
 *   npx hardhat run deploy/crosschain/01-deploy.ts --network base
 *   npx hardhat run deploy/crosschain/01-deploy.ts --network arbitrum
 *
 * - Every proxy is created with the Safe as ProxyAdmin owner (no SEC-001 window).
 * - Every proxy is initialized in the transaction that creates it (EpochVault,
 *   TickAccountant, ChainAgent via constructor data; the strategy Rebalancer via
 *   VaultFactory, because its initializer calls back into the proxy).
 * - During setup the deployer holds ADMIN_ROLE and acts as the "timelock" of the
 *   new contracts; phase 3 hands both to the Safe and the Timelock.
 *
 * Needs on the deployer: gas, and USDC for the seeds (hub: vault seed + strategy
 * seed; spoke: strategy seed).
 */
import { ethers } from 'hardhat';
import { HUB_PARAMS, NETWORKS, PROFILE, identities } from './registry';
import { Manifest, banner, codehash, currentEntry, deployer, readManifest, send, writeManifest } from './lib';

async function main() {
  const [key, entry] = await currentEntry();
  const ids = identities();
  const signer = await deployer();
  const me = await signer.getAddress();
  banner(`Phase 1 deploy (${entry.role})`);

  if (ids.stand) {
    console.log('  ! STAND profile: governance and roles may be a single EOA; stand-sized limits. Not for real TVL.');
  } else {
    for (const [label, addr] of Object.entries({ safe: ids.safe, navUpdater: ids.navUpdater, executor: ids.executor, guardian: ids.guardian })) {
      if (addr.toLowerCase() === me.toLowerCase()) throw new Error(`${label} must not be the deployer`);
    }
    if ((await ethers.provider.getCode(ids.safe)) === '0x') throw new Error(`Safe ${ids.safe} has no code on ${key}`);
  }

  const m: Manifest = readManifest(key) ?? {
    network: key,
    chainId: entry.chainId.toString(),
    role: entry.role,
    profile: PROFILE,
    deployer: me,
    startBlock: await ethers.provider.getBlockNumber(),
    phase: 0,
    contracts: {},
    codehashes: {},
    txs: {},
  };
  if (m.deployer.toLowerCase() !== me.toLowerCase()) throw new Error(`manifest was started by ${m.deployer}`);
  if ((m.profile ?? 'production') !== PROFILE) throw new Error(`manifest profile ${m.profile} != CROSSCHAIN_PROFILE ${PROFILE}`);
  const save = () => writeManifest(m);

  const usdc = await ethers.getContractAt('IERC20', entry.usdc, signer);

  async function deploy(name: string, contract: string, args: unknown[] = [], libraries?: Record<string, string>) {
    if (m.contracts[name]) {
      console.log(`  = ${name} ${m.contracts[name]}`);
      return m.contracts[name];
    }
    const factory = await ethers.getContractFactory(contract, { signer, libraries });
    const c = await factory.deploy(...args);
    await c.waitForDeployment();
    m.contracts[name] = await c.getAddress();
    m.txs[name] = c.deploymentTransaction()!.hash;
    m.codehashes[name] = await codehash(m.contracts[name]);
    save();
    console.log(`  ✓ ${name} ${m.contracts[name]}`);
    return m.contracts[name];
  }

  /** Transparent proxy initialized in its constructor; ProxyAdmin owned by the Safe. */
  async function deployProxy(name: string, implName: string, initData: string, seed?: bigint) {
    if (m.contracts[name]) {
      console.log(`  = ${name} ${m.contracts[name]}`);
      return m.contracts[name];
    }
    if (seed) {
      // the initializer pulls the seed from the proxy creator; approve the address the
      // proxy will have, i.e. the CREATE address of the transaction after the approve
      const nonce = await ethers.provider.getTransactionCount(me, 'pending');
      const predicted = ethers.getCreateAddress({ from: me, nonce: nonce + 1 });
      await send(`approve ${name} seed`, usdc.approve(predicted, seed) as any);
      const proxy = await deployRaw(name, implName, initData);
      if (proxy.toLowerCase() !== predicted.toLowerCase()) throw new Error(`${name}: address ${proxy} != predicted ${predicted}`);
      return proxy;
    }
    return deployRaw(name, implName, initData);
  }

  async function deployRaw(name: string, implName: string, initData: string) {
    const factory = await ethers.getContractFactory('TransparentUpgradeableProxy', signer);
    const c = await factory.deploy(m.contracts[implName], ids.safe, initData);
    await c.waitForDeployment();
    m.contracts[name] = await c.getAddress();
    m.txs[name] = c.deploymentTransaction()!.hash;
    save();
    console.log(`  ✓ ${name} ${m.contracts[name]} (proxy of ${implName})`);
    return m.contracts[name];
  }

  // governance
  await deploy('Timelock', 'Timelock', [ids.safe, ids.timelockDelay]);

  // strategy: Rebalancer over reused Aave/Morpho providers + a fresh Compound provider
  await deploy('VaultFactory', 'VaultFactory');
  const providers = entry.strategy.reusedProviders.map((p) => p.address);
  if (entry.strategy.comet) {
    const pm = await deploy('ProviderManager', 'ProviderManager', [me]);
    const pmc = await ethers.getContractAt('ProviderManager', pm, signer);
    if ((await pmc.getYieldToken('Compound_V3_Provider', entry.usdc)) === ethers.ZeroAddress) {
      await send('ProviderManager.setYieldToken(Compound)', pmc.setYieldToken('Compound_V3_Provider', entry.usdc, entry.strategy.comet));
    }
    const comp = await deploy('CompoundV3Provider', 'CompoundV3Provider', [pm]);
    providers.splice(1, 0, comp); // entry provider stays first
  }
  await deploy('StrategyImplementation', 'Rebalancer');
  if (!m.contracts.Strategy) {
    const seed = HUB_PARAMS.strategySeedAssets;
    const rebalancer = await ethers.getContractFactory('Rebalancer');
    const initData = rebalancer.interface.encodeFunctionData('initialize', [
      me, // admin during setup
      me, // timelock during setup
      entry.usdc,
      entry.strategy.name,
      entry.strategy.symbol,
      providers,
      ids.safe, // treasury
      0,
      0,
      seed,
    ]);
    const factory = await ethers.getContractAt('VaultFactory', m.contracts.VaultFactory, signer);
    await send('approve strategy seed', usdc.approve(m.contracts.VaultFactory, seed) as any);
    const tx = await factory.deployAndInitialize(m.contracts.StrategyImplementation, ids.safe, me, entry.usdc, seed, initData);
    const receipt = await tx.wait();
    const log = receipt!.logs.map((l: any) => { try { return factory.interface.parseLog(l); } catch { return null; } }).find((l: any) => l?.name === 'VaultDeployed');
    m.contracts.Strategy = log!.args.vault;
    m.txs.Strategy = tx.hash;
    save();
    console.log(`  ✓ Strategy ${m.contracts.Strategy}`);
  }

  // hub: accountant + vault
  const allChainIds = Object.values(NETWORKS).map((n) => n.chainId).sort((a, b) => (a < b ? -1 : 1));
  if (entry.role === 'hub') {
    await deploy('TickAccountantImplementation', 'TickAccountant');
    const acc = await ethers.getContractFactory('TickAccountant');
    const a = HUB_PARAMS.accountant;
    await deployProxy(
      'TickAccountant',
      'TickAccountantImplementation',
      acc.interface.encodeFunctionData('initialize', [
        me,
        me,
        ids.safe,
        allChainIds,
        [a.minTickInterval, a.maxSnapshotAge, a.maxTickAge, a.maxTransit, a.maxSpread, a.depositClearingMaxDown, a.maxInFlightRatio, a.maxOverdueInFlight],
        [HUB_PARAMS.upBucket.capacity, HUB_PARAMS.upBucket.refillPerSecond, 0, 0],
        [HUB_PARAMS.downBucket.capacity, HUB_PARAMS.downBucket.refillPerSecond, 0, 0],
      ]),
    );

    const logic = await deploy('EpochVaultLogic', 'contracts/tick/EpochVaultLogic.sol:EpochVaultLogic');
    await deploy('EpochVaultImplementation', 'EpochVault', [], { 'contracts/tick/EpochVaultLogic.sol:EpochVaultLogic': logic });
    const vf = await ethers.getContractFactory('EpochVault', { libraries: { 'contracts/tick/EpochVaultLogic.sol:EpochVaultLogic': logic } });
    const e = HUB_PARAMS.epoch;
    const l = HUB_PARAMS.limits;
    await deployProxy(
      'EpochVault',
      'EpochVaultImplementation',
      vf.interface.encodeFunctionData('initialize', [
        entry.usdc,
        HUB_PARAMS.vaultName,
        HUB_PARAMS.vaultSymbol,
        me,
        me,
        m.contracts.TickAccountant,
        HUB_PARAMS.seedAssets,
        [e.minDuration, e.maxDuration, e.minTicks, e.maxClearingDelay],
        [l.minDeposit, l.maxEpochDeposits, l.minimumBuffer, l.minBufferRatio, l.maxInstantWithdrawal, l.dailyInstantLimit, l.instantFee, l.instantMaxTickAge],
      ]),
      HUB_PARAMS.seedAssets,
    );
    const accountant = await ethers.getContractAt('TickAccountant', m.contracts.TickAccountant, signer);
    if ((await accountant.vault()) === ethers.ZeroAddress) {
      await send('TickAccountant.setVault', accountant.setVault(m.contracts.EpochVault));
    }
  }

  // agent + transport
  await deploy('ChainAgentImplementation', 'ChainAgent');
  const agentFactory = await ethers.getContractFactory('ChainAgent');
  await deployProxy(
    'ChainAgent',
    'ChainAgentImplementation',
    agentFactory.interface.encodeFunctionData('initialize', [
      entry.usdc,
      me,
      me,
      m.contracts.Strategy,
      entry.role === 'hub' ? m.contracts.EpochVault : ethers.ZeroAddress,
      entry.role === 'hub' ? m.contracts.TickAccountant : ethers.ZeroAddress,
    ]),
  );
  await deploy('CctpV2Adapter', 'CctpV2Adapter', [
    entry.usdc,
    m.contracts.ChainAgent,
    me,
    entry.cctp.tokenMessenger,
    entry.cctp.messageTransmitter,
    entry.cctp.minFinalityThreshold,
  ]);

  for (const name of ['Strategy', 'ChainAgent', 'TickAccountant', 'EpochVault']) {
    if (m.contracts[name]) m.codehashes[`${name}#proxy`] = await codehash(m.contracts[name]);
  }
  m.phase = Math.max(m.phase, 1);
  save();
  console.log(`\nPhase 1 complete for ${key}. Manifest: deployments/${key}/crosschain.json`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
