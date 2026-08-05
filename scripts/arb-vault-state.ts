import { ethers, network } from 'hardhat';
import * as fs from 'fs';

const ARB_USDC = '0xaf88d065e77c8cc2239327c5edb3a432268e5831';

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployment = JSON.parse(
    fs.readFileSync('deployments/arbitrum/USDCRebalancerProxy.json', 'utf8'),
  );

  const abi = [
    'function totalSupply() view returns (uint256)',
    'function totalAssets() view returns (uint256)',
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function getProviders() view returns (address[])',
    'function getMinAssets() view returns (uint256)',
    'function getEntryProvider() view returns (address)',
    'function balanceOf(address) view returns (uint256)',
  ];
  const vault = new ethers.Contract(deployment.address, abi, ethers.provider);
  const usdc = new ethers.Contract(ARB_USDC, abi, ethers.provider);

  try {
    const [supply, assets, name, symbol, providers, minAssets] =
      await Promise.all([
        vault.totalSupply(),
        vault.totalAssets(),
        vault.name(),
        vault.symbol(),
        vault.getProviders(),
        vault.getMinAssets(),
      ]);
    console.log('INITIALIZED: yes');
    console.log('name/symbol:', name, '/', symbol);
    console.log('totalSupply:', supply.toString());
    console.log('totalAssets:', assets.toString());
    console.log('providers:', providers.length);
    console.log('minAssets:', minAssets.toString());
  } catch {
    console.log('INITIALIZED: no');
  }

  const usdcBalance = await usdc.balanceOf(deployer.address);
  console.log('deployer USDC on Arbitrum:', usdcBalance.toString());

  // probe: would initialize revert right now?
  const proxyArtifact = await ethers.getContractAt('Rebalancer', deployment.address);
  try {
    await proxyArtifact.initialize.staticCall(
      process.env.TREASURY_ADDRESS!,
      ethers.ZeroAddress,
      ARB_USDC,
      'x',
      'x',
      [],
      process.env.TREASURY_ADDRESS!,
      0,
      0,
      1_000_000n,
    );
    console.log('initialize staticCall: would SUCCEED (vault uninitialized)');
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.includes('InvalidInitialization')) {
      console.log('initialize staticCall: InvalidInitialization (already initialized)');
    } else {
      console.log('initialize staticCall reverted:', msg.slice(0, 150));
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
