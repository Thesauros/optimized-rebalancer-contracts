import { Keypair, PublicKey } from '@solana/web3.js';
import { getAssociatedTokenAddressSync } from '@solana/spl-token';
import { getBytes } from 'ethers';
import { SOLANA } from '../../../deploy/crosschain/native-registry';
import { burnAccounts, bridgeData, executeInstruction, receiveAccounts, receiveData, pda } from './instructions';
import { Reader } from './codec';
import { SolanaSpoke } from './spoke';
import { sendNative, solanaSigner, nativeWriteGate } from './transactions';

export async function receiveOnSolana(
  spoke: SolanaSpoke,
  message: string,
  attestation: string,
  send: boolean,
): Promise<string> {
  return nativeWriteGate(async () => {
    const state = await spoke.state();
    const payer = solanaSigner('SOLANA_RELAYER_KEYPAIR');
    const tm = new PublicKey(SOLANA.cctp.tokenMessenger);
    const info = await spoke.connection.getAccountInfo(pda(tm, 'token_messenger'), 'finalized');
    if (!info || !info.owner.equals(tm)) throw new Error('Circle TokenMessenger state unavailable');
    // Anchor TokenMessenger: denylister, owner, pending_owner,
    // message_body_version:u32, authority_bump:u8, fee_recipient:Pubkey.
    const r = new Reader(info.data);
    r.take(8 + 32 * 3 + 4 + 1);
    const feeRecipient = r.key();
    const feeToken = getAssociatedTokenAddressSync(new PublicKey(SOLANA.asset.mint), feeRecipient, true);
    const ix = executeInstruction(
      spoke.program,
      spoke.agent,
      spoke.idle,
      payer.publicKey,
      state.sequence,
      state.strategies,
      receiveData(message, attestation),
      receiveAccounts(spoke.agent, spoke.idle, payer.publicKey, message, feeToken),
    );
    const transferId = Buffer.from(getBytes(message)).subarray(376, 408).toString('hex');
    return sendNative(spoke, [ix], payer, [], `receive-${transferId}`, send);
  });
}

export async function bridgeFromSolana(
  spoke: SolanaSpoke,
  amount: bigint,
  minimum: bigint,
  send: boolean,
): Promise<string> {
  return nativeWriteGate(async () => {
    const state = await spoke.state(),
      payer = solanaSigner(),
      event = Keypair.generate();
    const ix = executeInstruction(
      spoke.program,
      spoke.agent,
      spoke.idle,
      payer.publicKey,
      state.sequence,
      state.strategies,
      bridgeData(amount, minimum),
      burnAccounts(spoke.agent, spoke.idle, payer.publicKey, event.publicKey),
    );
    return sendNative(spoke, [ix], payer, [event], `send-${state.sequence}`, send);
  });
}
