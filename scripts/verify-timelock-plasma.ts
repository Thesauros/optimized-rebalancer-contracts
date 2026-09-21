import { run } from 'hardhat';
import * as fs from 'fs';

async function main() {
  const record = JSON.parse(
    fs.readFileSync('deployments/plasma/Timelock.json', 'utf8'),
  );
  try {
    await run('verify:verify', {
      address: record.address,
      constructorArguments: record.args || [],
    });
    console.log('Timelock: VERIFIED');
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg.toLowerCase().includes('already verified')) {
      console.log('Timelock: already verified');
    } else {
      console.log('Timelock: FAILED -', msg.slice(0, 300));
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
