use super::*;

fn evm(n: u8) -> [u8; 32] {
    let mut b = [0; 32];
    b[12..].fill(n);
    b
}
fn agent() -> Agent {
    Agent {
        seed: [0; 32],
        bump: 0,
        governance: Pubkey::new_unique(),
        executor: Pubkey::new_unique(),
        guardian: Pubkey::new_unique(),
        idle: Pubkey::new_unique(),
        paused: false,
        sequence: 0,
        route: Route {
            chain_id: 8453,
            domain: 6,
            agent: evm(1),
            adapter: evm(2),
            mint: evm(3),
            token_messenger: evm(4),
            max_per_transfer: 100_000_000,
            capacity: 200_000_000,
            refill_per_second: 100,
            max_fee_bps: 10,
        },
        level: 200_000_000,
        updated_at: 1000,
        strategies: vec![],
    }
}
fn strategy() -> Strategy {
    Strategy {
        protocol: 1,
        reserve: Pubkey::new_unique(),
        market: Pubkey::new_unique(),
        market_authority: Pubkey::new_unique(),
        liquidity_supply: Pubkey::new_unique(),
        collateral_mint: Pubkey::new_unique(),
        collateral: Pubkey::new_unique(),
        oracles: [
            Pubkey::new_unique(),
            Pubkey::new_unique(),
            Pubkey::new_unique(),
            Pubkey::new_unique(),
        ],
        cap: 100_000_000,
        retired: false,
    }
}
/// Minimal reserve at the pinned klend layout: 100 USDC available, no borrowed
/// amount and no fees, so one cToken is worth exactly one micro-USDC.
fn reserve(s: &Strategy, slot: u64, stale: u8) -> Vec<u8> {
    let mut d = vec![0u8; 2600];
    d[..8].copy_from_slice(&[43, 242, 204, 202, 26, 247, 59, 127]);
    d[8..16].copy_from_slice(&1u64.to_le_bytes());
    d[16..24].copy_from_slice(&slot.to_le_bytes());
    d[24] = stale;
    d[32..64].copy_from_slice(s.market.as_ref());
    d[128..160].copy_from_slice(USDC.as_ref());
    d[160..192].copy_from_slice(s.liquidity_supply.as_ref());
    d[224..232].copy_from_slice(&100_000_000u64.to_le_bytes());
    d[272..280].copy_from_slice(&6u64.to_le_bytes());
    d[2560..2592].copy_from_slice(s.collateral_mint.as_ref());
    d[2592..2600].copy_from_slice(&100_000_000u64.to_le_bytes());
    d
}
#[test]
fn route_identifies_base_and_rejects_native_keys_in_evm_fields() {
    let mut a = agent();
    assert!(a.route.validate().is_ok());
    a.route.agent[0] = 1;
    assert!(a.route.validate().is_err());
    a.route.agent = evm(1);
    a.route.chain_id = CHAIN;
    assert!(a.route.validate().is_err());
}
#[test]
fn route_limits_and_refill_are_bounded_in_integer_asset_units() {
    let mut a = agent();
    assert!(a.consume(100_000_001, 100_000_001, 1000).is_err());
    assert!(a.consume(1_000_000, 998_999, 1000).is_err());
    assert!(a.consume(100_000_000, 99_900_000, 1000).is_ok());
    assert!(a.consume(100_000_000, 100_000_000, 1000).is_ok());
    assert_eq!(a.level, 0);
    assert!(a.consume(1, 1, 1000).is_err());
    assert!(a.consume(1000, 1000, 1010).is_ok());
    assert_eq!(a.level, 0);
    assert!(a.consume(1, 1, 1009).is_err());
}
#[test]
fn fee_bound_rounds_up_instead_of_allowing_extra_micro_usdc() {
    let mut a = agent();
    assert!(a.consume(1001, 999, 1000).is_err());
    assert!(a.consume(1001, 1000, 1000).is_ok());
}
fn message(a: &Agent, who: &Pubkey) -> Vec<u8> {
    let mut b = vec![0; 440];
    for (at, n) in [(0, 1u32), (4, 6), (8, 5), (144, 2000), (148, 1)] {
        b[at..at + 4].copy_from_slice(&n.to_be_bytes());
    }
    for (at, w) in [
        (44, a.route.token_messenger),
        (76, CCTP.to_bytes()),
        (108, who.to_bytes()),
        (152, a.route.mint),
        (184, a.idle.to_bytes()),
        (248, a.route.adapter),
        (376, [9; 32]),
        (408, a.route.agent),
    ] {
        b[at..at + 32].copy_from_slice(&w);
    }
    b[240..248].copy_from_slice(&10_000_000u64.to_be_bytes());
    // Circle's body words between the source sender and the packed hook data.
    // This program reads none of them, so a plausible fee here proves nothing.
    b[336..344].copy_from_slice(&10_000u64.to_be_bytes());
    b
}
#[test]
fn cctp_authenticates_header_mint_caller_full_sender_and_hook() {
    let a = agent();
    let who = Pubkey::new_unique();
    let b = message(&a, &who);
    // The declared principal, not a net figure: Circle deducts its fee inside
    // the mint and no word of that body is authenticated here.
    let (id, amount) = validate_message(&b, &a, &who).unwrap();
    assert_eq!(id, [9; 32]);
    assert_eq!(amount, 10_000_000);
    for at in [0, 4, 8, 44, 76, 108, 152, 184, 216, 248, 408] {
        let mut bad = b.clone();
        bad[at] ^= 1;
        assert!(validate_message(&bad, &a, &who).is_err(), "offset {at}");
    }
    let mut bad = b.clone();
    bad[144..148].copy_from_slice(&1000u32.to_be_bytes());
    assert!(validate_message(&bad, &a, &who).is_err());
    assert!(validate_message(&b[..439], &a, &who).is_err());
}
#[test]
fn receive_accepts_a_message_whose_unauthenticated_body_words_are_garbage() {
    let a = agent();
    let who = Pubkey::new_unique();
    let mut b = message(&a, &who);
    // 280..376 is Circle's, not ours. Filling it with garbage is what a fee
    // encoded anywhere other than the word this program used to parse looks
    // like; the delivery must still be accepted at the measured amount.
    b[280..376].fill(0xa5);
    let (id, amount) = validate_message(&b, &a, &who).unwrap();
    assert_eq!(id, [9; 32]);
    assert_eq!(amount, 10_000_000);
    assert!(receive_bound(10_000_000, amount, a.route.max_fee_bps).is_ok());
    // A zero transfer id is still not a delivery.
    let mut bad = b.clone();
    bad[376..408].fill(0);
    assert!(validate_message(&bad, &a, &who).is_err());
}
#[test]
fn receive_binds_measured_custody_to_the_declared_principal_by_the_route_fee_cap() {
    let bps = 10u16;
    // Circle mints the declared amount when it takes no fee.
    assert!(receive_bound(10_000_000, 10_000_000, bps).is_ok());
    // Custody can never gain more than the message declared.
    assert!(receive_bound(10_000_001, 10_000_000, bps).is_err());
    // A zero delta is not a delivery, whatever the message says.
    assert!(receive_bound(0, 10_000_000, bps).is_err());
    // Exactly the route's fee cap is the last acceptable shortfall.
    assert!(receive_bound(9_990_000, 10_000_000, bps).is_ok());
    assert!(receive_bound(9_989_999, 10_000_000, bps).is_err());
    // The floor follows the cap rather than any wire figure.
    assert!(receive_bound(9_500_000, 10_000_000, 500).is_ok());
    assert!(receive_bound(9_499_999, 10_000_000, 500).is_err());
    assert!(receive_bound(1_000, 10_000_000, 9_999).is_ok());
    assert!(receive_bound(999, 10_000_000, 9_999).is_err());
    // u64 extremes widen without overflowing, and a cap beyond 100% is a route
    // fault rather than a panic.
    assert!(receive_bound(u64::MAX, u64::MAX, bps).is_ok());
    assert!(receive_bound(u64::MAX - u64::MAX / 100, u64::MAX, bps).is_err());
    assert_eq!(
        receive_bound(1, 1, 10_001).unwrap_err(),
        Error::from(AgentError::Limit)
    );
}
#[test]
fn retiring_a_strategy_requires_governance_and_empty_collateral() {
    let mut a = agent();
    a.strategies.push(strategy());
    let governance = a.governance;
    // R4: a strategy changes only with empty collateral.
    assert!(a.retire(&governance, 0, 1).is_err());
    assert!(!a.strategies[0].retired);
    assert!(a.retire(&governance, 0, 0).is_ok());
    assert!(a.strategies[0].retired);
    // Nobody else, and no slot that does not exist.
    assert!(a.retire(&Pubkey::new_unique(), 0, 0).is_err());
    assert!(a.retire(&governance, 1, 0).is_err());
    assert!(a.retire(&governance, u8::MAX, 0).is_err());
    assert!(a.strategies[0].retired);
}
#[test]
fn retired_strategies_carry_no_observation_accounts_and_stay_positionally_bound() {
    let live = [strategy(), strategy(), strategy()];
    assert_eq!(observation_plan(&live), vec![Some(0), Some(1), Some(2)]);
    let mut mixed = live.clone();
    mixed[1].retired = true;
    // One filter feeds the required count and the walk, so a retired slot
    // cannot shift the seven accounts belonging to the strategy after it.
    assert_eq!(observation_plan(&mixed), vec![Some(0), None, Some(1)]);
    let required = |s: &[Strategy]| observation_plan(s).iter().flatten().count() * 7 + 1;
    assert_eq!(required(&live), 22);
    assert_eq!(required(&mixed), 15);
    let mut all = live.clone();
    all.iter_mut().for_each(|s| s.retired = true);
    assert_eq!(required(&all), 1);
    assert_eq!(required(&[]), 1);
}
#[test]
fn a_dead_reserve_blocks_only_the_action_that_moves_value_through_it() {
    let s = strategy();
    let fresh = reserve(&s, 7, 0);
    // The valuation itself fails closed on a stale slot, a stale flag, an
    // unsupported version and a truncated reserve.
    assert_eq!(kamino::value(&fresh, &s, 1_000_000, 7).unwrap(), 1_000_000);
    assert_eq!(
        kamino::value(&fresh, &s, 0, 7).unwrap(),
        0,
        "no units means no exposure to the exchange rate"
    );
    let stale_slot = reserve(&s, 6, 0);
    let stale_flag = reserve(&s, 7, 1);
    let truncated = fresh[..2599].to_vec();
    for bad in [
        &stale_slot[..],
        &stale_flag[..],
        &truncated[..],
        &fresh[..8],
    ] {
        assert!(kamino::value(bad, &s, 1_000_000, 7).is_err());
    }
    let dead = || -> Result<u64> { Err(Error::from(AgentError::StaleReserve)) };
    // Deliveries and plain observations record the unknown and go through: a
    // reserve Kamino froze must not strand inbound USDC inside CCTP.
    assert_eq!(settle_observation(false, dead()).unwrap(), (0, true));
    assert_eq!(settle_observation(false, Ok(5)).unwrap(), (5, false));
    // Anything moving value fails closed, and an exit only for its own reserve.
    assert_eq!(
        settle_observation(true, dead()).unwrap_err(),
        dead().unwrap_err()
    );
    let deallocate = |at: u8| Action::Deallocate {
        index: at,
        amount: 1,
        minimum: 1,
    };
    assert!(fatal_observation(&deallocate(0), 0));
    assert!(
        !fatal_observation(&deallocate(0), 1),
        "an exit is not blocked by another strategy's dead reserve"
    );
    assert!(fatal_observation(
        &Action::Allocate {
            index: 0,
            amount: 1,
            minimum: 1
        },
        1
    ));
    assert!(fatal_observation(
        &Action::BridgeOut {
            amount: 1,
            min_receive: 1
        },
        0
    ));
    assert!(!fatal_observation(&Action::Observe, 0));
    assert!(!fatal_observation(
        &Action::Receive {
            message: vec![],
            attestation: vec![]
        },
        0
    ));
}
#[test]
fn pause_blocks_new_exposure_and_never_an_exit_delivery_or_observation() {
    let allocate = Action::Allocate {
        index: 0,
        amount: 1,
        minimum: 1,
    };
    assert!(pause_blocks(&allocate));
    assert!(pause_blocks(&Action::BridgeOut {
        amount: 1,
        min_receive: 1
    }));
    assert!(!pause_blocks(&Action::Deallocate {
        index: 0,
        amount: 1,
        minimum: 1
    }));
    assert!(!pause_blocks(&Action::Observe));
    assert!(!pause_blocks(&Action::Receive {
        message: vec![],
        attestation: vec![]
    }));
}
#[test]
fn initialize_is_bound_to_the_recorded_program_upgrade_authority() {
    let authority = Pubkey::new_unique();
    let mut data = vec![0u8; 45 + 8];
    data[..4].copy_from_slice(&3u32.to_le_bytes());
    data[4..12].copy_from_slice(&7u64.to_le_bytes());
    data[12] = 1;
    data[13..45].copy_from_slice(authority.as_ref());
    assert_eq!(program_upgrade_authority(&data).unwrap(), authority);
    // An immutable program records no authority, so nothing can ever sign this:
    // initialize is impossible by design and the build must be deployed under a
    // reviewed upgrade authority.
    data[12] = 0;
    assert_eq!(
        program_upgrade_authority(&data).unwrap_err(),
        Error::from(AgentError::Immutable)
    );
    // A Buffer, Program or Uninitialized tag is not ProgramData.
    for tag in [0u32, 1, 2, 4] {
        let mut other = data.clone();
        other[12] = 1;
        other[..4].copy_from_slice(&tag.to_le_bytes());
        assert_eq!(
            program_upgrade_authority(&other).unwrap_err(),
            Error::from(AgentError::Accounts),
            "tag {tag}"
        );
    }
    // A header shorter than 45 bytes cannot carry an authority.
    assert!(program_upgrade_authority(&data[..44]).is_err());
    assert!(program_upgrade_authority(&[]).is_err());
    // The pinned address comes from this program's id alone, so a squatter
    // cannot substitute another program's authority for the reviewed one.
    let (program_data, bump) = Pubkey::find_program_address(&[crate::id().as_ref()], &LOADER);
    assert_eq!(
        program_data,
        Pubkey::create_program_address(&[crate::id().as_ref(), &[bump]], &LOADER).unwrap()
    );
    assert_ne!(program_data, crate::id());
    assert_ne!(LOADER, crate::id());
}
#[test]
fn agent_account_space_covers_the_maximum_strategy_set_with_retirement() {
    let a = Agent {
        strategies: (0..MAX_STRATEGIES).map(|_| strategy()).collect(),
        ..agent()
    };
    let mut bytes = vec![];
    a.try_serialize(&mut bytes).unwrap();
    // 364 bytes of fixed fields plus 330 per strategy, including `retired`.
    assert_eq!(bytes.len(), 364 + 330 * MAX_STRATEGIES);
    assert!(
        bytes.len() <= 4096,
        "the Agent rent allocation no longer fits the strategy set"
    );
}
#[test]
fn checkpoint_rent_allocation_matches_canonical_serialization_at_every_capacity() {
    for n in 0..=MAX_STRATEGIES {
        let cp = Checkpoint {
            agent: Pubkey::new_unique(),
            sequence: 0,
            slot: 1,
            timestamp: 1,
            idle: 0,
            positions: (0..n)
                .map(|_| Observation {
                    reserve: Pubkey::new_unique(),
                    units: 0,
                    value: 0,
                    observation_failed: false,
                })
                .collect(),
            movement: Movement::default(),
        };
        let mut bytes = vec![];
        cp.try_serialize(&mut bytes).unwrap();
        assert_eq!(bytes.len(), 133 + 49 * n);
    }
}
