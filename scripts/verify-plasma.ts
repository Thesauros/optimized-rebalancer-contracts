import { run } from 'hardhat';
import * as fs from 'fs';

async function main() {
  const dir = 'deployments/plasma';
  const names = fs.readdirSync(dir).filter((f) => f.endsWith('.json'));
  for (const f of names) {
    const record = JSON.parse(fs.readFileSync(`${dir}/${f}`, 'utf8'));
    const label = f.replace('.json', '');
    try {
      await run('verify:verify', {
        address: record.address,
        constructorArguments: record.args || [],
      });
      console.log(`${label}: VERIFIED`);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.toLowerCase().includes('already verified')) {
        console.log(`${label}: already verified`);
      } else {
        console.log(`${label}: FAILED - ${msg.slice(0, 200)}`);
      }
    }
    await new Promise((r) => setTimeout(r, 1200));
  }
  console.log('VERIFY_PLASMA_DONE');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
