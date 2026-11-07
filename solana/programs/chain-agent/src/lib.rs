use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta, Instruction},
    keccak,
    program::invoke_signed,
};
use anchor_spl::token::{Mint, Token, TokenAccount};
pub mod kamino;

// Source ID, not a deployment claim. Generate/verify the corresponding program
// keypair and retain this ID before deploying a reviewed build.
declare_id!("Fg6PaFpoGXkYsidMpWxTWqkZ2dKjF6Q6Bf6WZ7H6LJ7");
pub const USDC: Pubkey = pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const CCTP: Pubkey = pubkey!("CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe");
pub const TRANSMITTER: Pubkey = pubkey!("CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC");
pub const CHAIN: u64 = 0x8000000000000005;
pub const MAX_STRATEGIES: usize = 8;

#[program]
pub mod thesauros_chain_agent {
    use super::*;

    /// Append-only loss history, separate from immutable custody observations.
    /// Referencing the original send binds the hard cumulative write-down cap.
    pub fn write_down(
        ctx: Context<WriteDown>,
        transfer_id: [u8; 32],
        amount: u64,
        reason: [u8; 32],
    ) -> Result<()> {
        let original = &ctx.accounts.sent;
        require!(
            original.agent == ctx.accounts.agent.key()
                && original.movement.kind == 1
                && original.movement.transfer_id == transfer_id
                && amount > 0
                && reason != [0u8; 32],
            AgentError::Amount
        );
        let loss = &mut ctx.accounts.loss;
        if loss.agent == Pubkey::default() {
            loss.agent = ctx.accounts.agent.key();
            loss.transfer_id = transfer_id;
        }
        require!(
            loss.agent == ctx.accounts.agent.key()
                && loss.transfer_id == transfer_id
                && loss.entries.len() < 32,
            AgentError::Accounts
        );
        let total = loss
            .total
            .checked_add(amount)
            .ok_or(AgentError::Arithmetic)?;
        require!(total <= original.movement.amount, AgentError::Limit);
        loss.total = total;
        let clock = Clock::get()?;
        loss.entries.push(LossEntry {
            slot: clock.slot,
            amount,
            reason,
        });
        Ok(())
    }

    pub fn initialize(
        ctx: Context<Initialize>,
        seed: [u8; 32],
        executor: Pubkey,
        guardian: Pubkey,
        route: Route,
    ) -> Result<()> {
        route.validate()?;
        require!(
            executor != Pubkey::default() && guardian != Pubkey::default(),
            AgentError::Accounts
        );
        let a = &mut ctx.accounts.agent;
        a.seed = seed;
        a.bump = ctx.bumps.agent;
        a.governance = ctx.accounts.governance.key();
        a.executor = executor;
        a.guardian = guardian;
        a.idle = ctx.accounts.idle.key();
        // Deploy inactive; governance unpauses after both bridge endpoints and
        // the hub accountant have been verified. Receives/exits remain open.
        a.paused = true;
        a.route = route;
        a.level = a.route.capacity;
        a.updated_at = Clock::get()?.unix_timestamp;
        Ok(())
    }

    /// Governance is expected to be a timelocked multisig PDA. It can add
    /// independent reserve adapters; it cannot mutate an existing endpoint.
    pub fn add_strategy(ctx: Context<Govern>, strategy: Strategy) -> Result<()> {
        let a = &mut ctx.accounts.agent;
        require!(
            a.strategies.len() < MAX_STRATEGIES && strategy.protocol == 1,
            AgentError::Protocol
        );
        require!(
            !a.strategies
                .iter()
                .any(|s| s.reserve == strategy.reserve || s.collateral == strategy.collateral),
            AgentError::Accounts
        );
        require!(
            strategy.reserve != Pubkey::default() && strategy.cap > 0,
            AgentError::Accounts
        );
        a.strategies.push(strategy);
        Ok(())
    }

    pub fn set_roles(
        ctx: Context<Govern>,
        governance: Pubkey,
        executor: Pubkey,
        guardian: Pubkey,
    ) -> Result<()> {
        require!(
            [governance, executor, guardian]
                .iter()
                .all(|k| *k != Pubkey::default()),
            AgentError::Accounts
        );
        let a = &mut ctx.accounts.agent;
        a.governance = governance;
        a.executor = executor;
        a.guardian = guardian;
        Ok(())
    }

    pub fn pause(ctx: Context<Pause>, paused: bool) -> Result<()> {
        let a = &mut ctx.accounts.agent;
        let who = ctx.accounts.authority.key();
        require!(
            who == a.governance || (paused && who == a.guardian),
            AgentError::Unauthorized
        );
        a.paused = paused;
        Ok(())
    }

    /// Every operation creates an immutable checkpoint in this same transaction.
    /// Accounts after the action-specific CPI prefix: [reserve, market,
    /// collateral token account, pyth, switchboard price, switchboard twap,
    /// scope] for EACH registered strategy, then the Kamino executable.
    pub fn execute<'info>(
        ctx: Context<'_, '_, '_, 'info, Execute<'info>>,
        action: Action,
    ) -> Result<()> {
        let now = Clock::get()?;
        let agent_key = ctx.accounts.agent.key();
        let seed = ctx.accounts.agent.seed;
        let bump = [ctx.accounts.agent.bump];
        let seeds: &[&[u8]] = &[b"agent", &seed, &bump];
        let mut prefix = 0usize;
        let mut movement = Movement::default();
        let before = ctx.accounts.idle.amount;
        match action.clone() {
            Action::Observe => {}
            Action::Allocate {
                index,
                amount,
                minimum,
            }
            | Action::Deallocate {
                index,
                amount,
                minimum,
            } => {
                let deposit = matches!(action, Action::Allocate { .. });
                let a = &ctx.accounts.agent;
                require_keys_eq!(
                    ctx.accounts.payer.key(),
                    a.executor,
                    AgentError::Unauthorized
                );
                require!(!deposit || !a.paused, AgentError::Paused);
                require!(amount > 0 && minimum > 0, AgentError::Amount);
                let s = a
                    .strategies
                    .get(index as usize)
                    .ok_or(AgentError::Protocol)?;
                require!(s.protocol == 1, AgentError::Protocol);
                let accounts = ctx
                    .remaining_accounts
                    .get(..13)
                    .ok_or(AgentError::Accounts)?;
                require_keys_eq!(accounts[12].key(), kamino::PROGRAM, AgentError::Accounts);
                // Refresh before a deposit/redeem as well as before valuation.
                // The lending instruction marks the reserve stale afterwards.
                let o = ctx
                    .remaining_accounts
                    .get(13 + index as usize * 7..13 + index as usize * 7 + 7)
                    .ok_or(AgentError::Accounts)?;
                let mut refresh = vec![o[0].clone(), o[1].clone()];
                refresh.extend_from_slice(&o[3..]);
                refresh.push(accounts[12].clone());
                call(
                    kamino::PROGRAM,
                    &refresh,
                    &[
                        s.reserve,
                        s.market,
                        s.oracles[0],
                        s.oracles[1],
                        s.oracles[2],
                        s.oracles[3],
                    ],
                    &[0],
                    &[],
                    kamino::REFRESH.to_vec(),
                    seeds,
                )?;
                let collateral_before = read_token(
                    &accounts[if deposit { 8 } else { 7 }],
                    &s.collateral,
                    &s.collateral_mint,
                    &agent_key,
                )?;
                let expected = if deposit {
                    vec![
                        agent_key,
                        s.reserve,
                        s.market,
                        s.market_authority,
                        USDC,
                        s.liquidity_supply,
                        s.collateral_mint,
                        a.idle,
                        s.collateral,
                        anchor_spl::token::ID,
                        anchor_spl::token::ID,
                        anchor_lang::solana_program::sysvar::instructions::ID,
                    ]
                } else {
                    vec![
                        agent_key,
                        s.market,
                        s.reserve,
                        s.market_authority,
                        USDC,
                        s.collateral_mint,
                        s.liquidity_supply,
                        s.collateral,
                        a.idle,
                        anchor_spl::token::ID,
                        anchor_spl::token::ID,
                        anchor_lang::solana_program::sysvar::instructions::ID,
                    ]
                };
                let writable: &[usize] = if deposit {
                    &[1, 5, 6, 7, 8]
                } else {
                    &[2, 5, 6, 7, 8]
                };
                let mut data = if deposit {
                    kamino::DEPOSIT.to_vec()
                } else {
                    kamino::REDEEM.to_vec()
                };
                data.extend_from_slice(&amount.to_le_bytes());
                call(
                    kamino::PROGRAM,
                    accounts,
                    &expected,
                    writable,
                    &[0],
                    data,
                    seeds,
                )?;
                ctx.accounts.idle.reload()?;
                let collateral_after = read_token(
                    &accounts[if deposit { 8 } else { 7 }],
                    &s.collateral,
                    &s.collateral_mint,
                    &agent_key,
                )?;
                if deposit {
                    require!(
                        before.checked_sub(ctx.accounts.idle.amount) == Some(amount)
                            && collateral_after
                                .checked_sub(collateral_before)
                                .is_some_and(|x| x >= minimum),
                        AgentError::Slippage
                    );
                } else {
                    require!(
                        collateral_before.checked_sub(collateral_after) == Some(amount)
                            && ctx
                                .accounts
                                .idle
                                .amount
                                .checked_sub(before)
                                .is_some_and(|x| x >= minimum),
                        AgentError::Slippage
                    );
                }
                prefix = 13;
            }
            Action::BridgeOut {
                amount,
                min_receive,
            } => {
                let a = &mut ctx.accounts.agent;
                require_keys_eq!(
                    ctx.accounts.payer.key(),
                    a.executor,
                    AgentError::Unauthorized
                );
                require!(!a.paused, AgentError::Paused);
                a.consume(amount, min_receive, now.unix_timestamp)?;
                let nonce = a.sequence.to_be_bytes();
                let transfer_id =
                    keccak::hashv(&[b"thesauros.solana.transfer.v1:", agent_key.as_ref(), &nonce])
                        .to_bytes();
                let mut hook = transfer_id.to_vec();
                hook.extend_from_slice(agent_key.as_ref());
                let mut data = discriminator("global:deposit_for_burn_with_hook").to_vec();
                data.extend_from_slice(&amount.to_le_bytes());
                data.extend_from_slice(&a.route.domain.to_le_bytes());
                data.extend_from_slice(&a.route.agent);
                data.extend_from_slice(&a.route.adapter);
                data.extend_from_slice(&(amount - min_receive).to_le_bytes());
                data.extend_from_slice(&2000u32.to_le_bytes());
                data.extend_from_slice(&64u32.to_le_bytes());
                data.extend_from_slice(&hook);
                // Circle's own Anchor validation authenticates every PDA/account.
                let accounts = ctx
                    .remaining_accounts
                    .get(..19)
                    .ok_or(AgentError::Accounts)?;
                require_keys_eq!(accounts[0].key(), agent_key, AgentError::Accounts);
                require_keys_eq!(
                    accounts[1].key(),
                    ctx.accounts.payer.key(),
                    AgentError::Accounts
                );
                require_keys_eq!(accounts[3].key(), a.idle, AgentError::Accounts);
                require_keys_eq!(accounts[10].key(), USDC, AgentError::Accounts);
                require_keys_eq!(accounts[12].key(), TRANSMITTER, AgentError::Accounts);
                require_keys_eq!(accounts[13].key(), CCTP, AgentError::Accounts);
                require_keys_eq!(
                    accounts[14].key(),
                    anchor_spl::token::ID,
                    AgentError::Accounts
                );
                cctp_call(CCTP, accounts, &[0, 1, 11], seeds, data)?;
                ctx.accounts.idle.reload()?;
                require!(
                    before.checked_sub(ctx.accounts.idle.amount) == Some(amount),
                    AgentError::Slippage
                );
                movement = Movement {
                    kind: 1,
                    transfer_id,
                    peer_chain: a.route.chain_id,
                    amount,
                    minimum: min_receive,
                };
                prefix = 19;
            }
            Action::Receive {
                message,
                attestation,
            } => {
                let a = &ctx.accounts.agent;
                let (id, expected) = validate_message(&message, a, &agent_key)?;
                let mut data = discriminator("global:receive_message").to_vec();
                data.extend_from_slice(&(message.len() as u32).to_le_bytes());
                data.extend_from_slice(&message);
                data.extend_from_slice(&(attestation.len() as u32).to_le_bytes());
                data.extend_from_slice(&attestation);
                let accounts = ctx
                    .remaining_accounts
                    .get(..21)
                    .ok_or(AgentError::Accounts)?;
                require_keys_eq!(
                    accounts[0].key(),
                    ctx.accounts.payer.key(),
                    AgentError::Accounts
                );
                require_keys_eq!(accounts[1].key(), agent_key, AgentError::Accounts);
                require_keys_eq!(accounts[5].key(), CCTP, AgentError::Accounts);
                // Nine transmitter accounts (including event CPI), then the
                // TokenMessenger recipient at remaining-account offset six.
                require_keys_eq!(accounts[15].key(), a.idle, AgentError::Accounts);
                cctp_call(TRANSMITTER, accounts, &[0, 1], seeds, data)?;
                ctx.accounts.idle.reload()?;
                let received = ctx
                    .accounts
                    .idle
                    .amount
                    .checked_sub(before)
                    .ok_or(AgentError::Slippage)?;
                require!(received == expected && received > 0, AgentError::Slippage);
                movement = Movement {
                    kind: 2,
                    transfer_id: id,
                    peer_chain: a.route.chain_id,
                    amount: received,
                    minimum: received,
                };
                prefix = 21;
            }
        }
        let a = &ctx.accounts.agent;
        let tail = ctx
            .remaining_accounts
            .get(prefix..)
            .ok_or(AgentError::Accounts)?;
        require!(
            tail.len() == a.strategies.len() * 7 + 1,
            AgentError::Accounts
        );
        require_keys_eq!(
            tail.last().unwrap().key(),
            kamino::PROGRAM,
            AgentError::Accounts
        );
        let mut positions = Vec::with_capacity(a.strategies.len());
        for (i, s) in a.strategies.iter().enumerate() {
            let accounts = &tail[i * 7..i * 7 + 7];
            let expected = [
                s.reserve,
                s.market,
                s.oracles[0],
                s.oracles[1],
                s.oracles[2],
                s.oracles[3],
            ];
            let mut infos = vec![accounts[0].clone(), accounts[1].clone()];
            infos.extend_from_slice(&accounts[3..]);
            infos.push(tail.last().unwrap().clone());
            call(
                kamino::PROGRAM,
                &infos,
                &expected,
                &[0],
                &[],
                kamino::REFRESH.to_vec(),
                seeds,
            )?;
            require_keys_eq!(*accounts[0].owner, kamino::PROGRAM, AgentError::Accounts);
            let units = read_token(&accounts[2], &s.collateral, &s.collateral_mint, &agent_key)?;
            let value = kamino::value(&accounts[0].try_borrow_data()?, s, units, now.slot)?;
            if matches!(action, Action::Allocate { .. }) {
                require!(value <= s.cap, AgentError::Limit);
            }
            positions.push(Observation {
                reserve: s.reserve,
                units,
                value,
            });
        }
        let cp = &mut ctx.accounts.checkpoint;
        cp.agent = agent_key;
        cp.sequence = a.sequence;
        cp.slot = now.slot;
        cp.timestamp = now.unix_timestamp;
        cp.idle = ctx.accounts.idle.amount;
        cp.positions = positions;
        cp.movement = movement;
        ctx.accounts.agent.sequence = a.sequence.checked_add(1).ok_or(AgentError::Arithmetic)?;
        Ok(())
    }
}

fn discriminator(name: &str) -> [u8; 8] {
    anchor_lang::solana_program::hash::hash(name.as_bytes()).to_bytes()[..8]
        .try_into()
        .unwrap()
}

fn read_token(info: &AccountInfo, key: &Pubkey, mint: &Pubkey, authority: &Pubkey) -> Result<u64> {
    require_keys_eq!(info.key(), *key, AgentError::Accounts);
    require_keys_eq!(*info.owner, anchor_spl::token::ID, AgentError::Accounts);
    let t = TokenAccount::try_deserialize_unchecked(&mut &info.try_borrow_data()?[..])?;
    require_keys_eq!(t.mint, *mint, AgentError::Accounts);
    require_keys_eq!(t.owner, *authority, AgentError::Accounts);
    require!(
        t.delegate.is_none() && t.close_authority.is_none(),
        AgentError::Accounts
    );
    Ok(t.amount)
}

fn call<'info>(
    program: Pubkey,
    infos: &[AccountInfo<'info>],
    expected: &[Pubkey],
    writable: &[usize],
    signers: &[usize],
    data: Vec<u8>,
    seeds: &[&[u8]],
) -> Result<()> {
    require!(infos.len() == expected.len() + 1, AgentError::Accounts);
    require_keys_eq!(infos.last().unwrap().key(), program, AgentError::Accounts);
    require!(infos.last().unwrap().executable, AgentError::Accounts);
    let mut metas = Vec::with_capacity(expected.len());
    for (i, key) in expected.iter().enumerate() {
        require_keys_eq!(infos[i].key(), *key, AgentError::Accounts);
        metas.push(if writable.contains(&i) {
            AccountMeta::new(*key, signers.contains(&i))
        } else {
            AccountMeta::new_readonly(*key, signers.contains(&i))
        });
    }
    invoke_signed(
        &Instruction {
            program_id: program,
            accounts: metas,
            data,
        },
        infos,
        &[seeds],
    )?;
    Ok(())
}

fn cctp_call<'info>(
    program: Pubkey,
    infos: &[AccountInfo<'info>],
    signers: &[usize],
    seeds: &[&[u8]],
    data: Vec<u8>,
) -> Result<()> {
    require_keys_eq!(infos.last().unwrap().key(), program, AgentError::Accounts);
    require!(infos.last().unwrap().executable, AgentError::Accounts);
    let metas = infos[..infos.len() - 1]
        .iter()
        .enumerate()
        .map(|(i, a)| {
            if a.is_writable {
                AccountMeta::new(a.key(), signers.contains(&i))
            } else {
                AccountMeta::new_readonly(a.key(), signers.contains(&i))
            }
        })
        .collect();
    invoke_signed(
        &Instruction {
            program_id: program,
            accounts: metas,
            data,
        },
        infos,
        &[seeds],
    )?;
    Ok(())
}

fn word(b: &[u8], at: usize) -> Result<[u8; 32]> {
    Ok(b.get(at..at + 32)
        .ok_or(AgentError::Message)?
        .try_into()
        .unwrap())
}
fn be32(b: &[u8], at: usize) -> Result<u32> {
    Ok(u32::from_be_bytes(
        b.get(at..at + 4)
            .ok_or(AgentError::Message)?
            .try_into()
            .unwrap(),
    ))
}
fn validate_message(b: &[u8], a: &Agent, agent: &Pubkey) -> Result<([u8; 32], u64)> {
    require!(
        b.len() == 440
            && be32(b, 0)? == 1
            && be32(b, 4)? == a.route.domain
            && be32(b, 8)? == 5
            && be32(b, 144)? >= 2000
            && be32(b, 148)? == 1,
        AgentError::Message
    );
    require!(
        word(b, 44)? == a.route.token_messenger
            && word(b, 76)? == CCTP.to_bytes()
            && word(b, 108)? == agent.to_bytes()
            && word(b, 152)? == a.route.mint
            && word(b, 184)? == a.idle.to_bytes()
            && word(b, 248)? == a.route.adapter
            && word(b, 408)? == a.route.agent,
        AgentError::Message
    );
    let amount = word(b, 216)?;
    let fee = word(b, 312)?;
    require!(
        amount[..24] == [0u8; 24] && fee[..24] == [0u8; 24],
        AgentError::Message
    );
    let net = u64::from_be_bytes(amount[24..].try_into().unwrap())
        .checked_sub(u64::from_be_bytes(fee[24..].try_into().unwrap()))
        .ok_or(AgentError::Message)?;
    let id = word(b, 376)?;
    require!(id != [0u8; 32], AgentError::Message);
    Ok((id, net))
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub enum Action {
    Observe,
    Allocate {
        index: u8,
        amount: u64,
        minimum: u64,
    },
    Deallocate {
        index: u8,
        amount: u64,
        minimum: u64,
    },
    BridgeOut {
        amount: u64,
        min_receive: u64,
    },
    Receive {
        message: Vec<u8>,
        attestation: Vec<u8>,
    },
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Default)]
pub struct Route {
    pub chain_id: u64,
    pub domain: u32,
    pub agent: [u8; 32],
    pub adapter: [u8; 32],
    pub mint: [u8; 32],
    pub token_messenger: [u8; 32],
    pub max_per_transfer: u64,
    pub capacity: u64,
    pub refill_per_second: u64,
    pub max_fee_bps: u16,
}
impl Route {
    fn validate(&self) -> Result<()> {
        require!(
            self.chain_id == 8453
                && self.domain == 6
                && self.max_fee_bps < 10000
                && self.max_per_transfer > 0
                && self.capacity >= self.max_per_transfer
                && [self.agent, self.adapter, self.mint, self.token_messenger]
                    .iter()
                    .all(|x| *x != [0u8; 32] && x[..12] == [0u8; 12]),
            AgentError::Accounts
        );
        Ok(())
    }
}
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct Strategy {
    pub protocol: u8,
    pub reserve: Pubkey,
    pub market: Pubkey,
    pub market_authority: Pubkey,
    pub liquidity_supply: Pubkey,
    pub collateral_mint: Pubkey,
    pub collateral: Pubkey,
    pub oracles: [Pubkey; 4],
    pub cap: u64,
}
#[account]
pub struct Agent {
    pub seed: [u8; 32],
    pub bump: u8,
    pub governance: Pubkey,
    pub executor: Pubkey,
    pub guardian: Pubkey,
    pub idle: Pubkey,
    pub paused: bool,
    pub sequence: u64,
    pub route: Route,
    pub level: u64,
    pub updated_at: i64,
    pub strategies: Vec<Strategy>,
}
impl Agent {
    fn consume(&mut self, amount: u64, minimum: u64, now: i64) -> Result<()> {
        require!(
            amount > 0 && minimum > 0 && minimum <= amount,
            AgentError::Amount
        );
        require!(
            amount <= self.route.max_per_transfer
                && (minimum as u128) * 10000
                    >= (amount as u128) * (10000 - self.route.max_fee_bps as u128),
            AgentError::Limit
        );
        let elapsed = now
            .checked_sub(self.updated_at)
            .ok_or(AgentError::Arithmetic)?;
        require!(elapsed >= 0, AgentError::Arithmetic);
        let level = (self.level as u128 + elapsed as u128 * self.route.refill_per_second as u128)
            .min(self.route.capacity as u128) as u64;
        self.level = level.checked_sub(amount).ok_or(AgentError::Limit)?;
        self.updated_at = now;
        Ok(())
    }
}
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Default)]
pub struct Movement {
    pub kind: u8,
    pub transfer_id: [u8; 32],
    pub peer_chain: u64,
    pub amount: u64,
    pub minimum: u64,
}
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct Observation {
    pub reserve: Pubkey,
    pub units: u64,
    pub value: u64,
}
#[account]
pub struct Checkpoint {
    pub agent: Pubkey,
    pub sequence: u64,
    pub slot: u64,
    pub timestamp: i64,
    pub idle: u64,
    pub positions: Vec<Observation>,
    pub movement: Movement,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct LossEntry {
    pub slot: u64,
    pub amount: u64,
    pub reason: [u8; 32],
}
#[account]
pub struct Loss {
    pub agent: Pubkey,
    pub transfer_id: [u8; 32],
    pub total: u64,
    pub entries: Vec<LossEntry>,
}

#[derive(Accounts)]
#[instruction(transfer_id:[u8;32])]
pub struct WriteDown<'info> {
    #[account(seeds=[b"agent",agent.seed.as_ref()],bump=agent.bump,has_one=governance)]
    pub agent: Account<'info, Agent>,
    pub sent: Account<'info, Checkpoint>,
    #[account(init_if_needed,payer=governance,space=8+32+32+8+4+32*48,seeds=[b"loss",agent.key().as_ref(),transfer_id.as_ref()],bump)]
    pub loss: Account<'info, Loss>,
    #[account(mut)]
    pub governance: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(seed:[u8;32])]
pub struct Initialize<'info> {
    #[account(init,payer=governance,space=4096,seeds=[b"agent",seed.as_ref()],bump)]
    pub agent: Account<'info, Agent>,
    #[account(mut)]
    pub governance: Signer<'info>,
    #[account(init,payer=governance,token::mint=mint,token::authority=agent,seeds=[b"idle",agent.key().as_ref()],bump)]
    pub idle: Account<'info, TokenAccount>,
    #[account(address=USDC)]
    pub mint: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}
#[derive(Accounts)]
pub struct Govern<'info> {
    #[account(mut,seeds=[b"agent",agent.seed.as_ref()],bump=agent.bump,has_one=governance)]
    pub agent: Account<'info, Agent>,
    pub governance: Signer<'info>,
}
#[derive(Accounts)]
pub struct Pause<'info> {
    #[account(mut,seeds=[b"agent",agent.seed.as_ref()],bump=agent.bump)]
    pub agent: Account<'info, Agent>,
    pub authority: Signer<'info>,
}
#[derive(Accounts)]
pub struct Execute<'info> {
    #[account(mut,seeds=[b"agent",agent.seed.as_ref()],bump=agent.bump,has_one=idle)]
    pub agent: Account<'info, Agent>,
    #[account(mut,token::mint=USDC,token::authority=agent)]
    pub idle: Account<'info, TokenAccount>,
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(init,payer=payer,space=133+48*agent.strategies.len(),seeds=[b"checkpoint",agent.key().as_ref(),agent.sequence.to_le_bytes().as_ref()],bump)]
    pub checkpoint: Account<'info, Checkpoint>,
    pub system_program: Program<'info, System>,
}
#[error_code]
pub enum AgentError {
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("New allocation and bridge sends are paused")]
    Paused,
    #[msg("Invalid protocol")]
    Protocol,
    #[msg("Unexpected account binding")]
    Accounts,
    #[msg("Invalid amount")]
    Amount,
    #[msg("Route or strategy limit exceeded")]
    Limit,
    #[msg("Measured movement violates minimum")]
    Slippage,
    #[msg("Unsupported Kamino reserve layout")]
    ReserveLayout,
    #[msg("Refresh reserve in the same slot")]
    StaleReserve,
    #[msg("Arithmetic overflow")]
    Arithmetic,
    #[msg("Invalid bridge message")]
    Message,
}

#[cfg(test)]
mod security_tests;
