/**
 * NAV updater, keeper and relayer in one process.
 *
 * For deployments where these roles share one key (the stand: every role is
 * the deployer EOA). Separate processes would each keep their own nonce counter
 * for the same address and overwrite each other's transactions; in one process
 * `signerFor` hands all three the same NonceManager, which assigns nonces
 * synchronously. Each service keeps its own loop, status port and log tag.
 *
 * With distinct keys per role, run the three services separately instead.
 */
import { Wallet } from 'ethers';
import { log } from './util';

const roles = ['NAV_UPDATER_PRIVATE_KEY', 'KEEPER_PRIVATE_KEY', 'RELAYER_PRIVATE_KEY'];
const addresses = new Set(roles.map((k) => (process.env[k] ? new Wallet(process.env[k]!).address : k)));
log('operators', 'starting nav, keeper and relayer in one process', { distinctSigners: addresses.size });

require('./nav');
require('./keeper');
require('./relayer');
