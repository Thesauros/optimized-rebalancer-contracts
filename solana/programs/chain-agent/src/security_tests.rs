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
    b[336..344].copy_from_slice(&10_000u64.to_be_bytes());
    b
}
#[test]
fn cctp_authenticates_header_mint_caller_full_sender_and_hook() {
    let a = agent();
    let who = Pubkey::new_unique();
    let b = message(&a, &who);
    let (_, amount) = validate_message(&b, &a, &who).unwrap();
    assert_eq!(amount, 9_990_000);
    for at in [0, 4, 8, 44, 76, 108, 152, 184, 248, 408] {
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
                })
                .collect(),
            movement: Movement::default(),
        };
        let mut bytes = vec![];
        cp.try_serialize(&mut bytes).unwrap();
        assert_eq!(bytes.len(), 133 + 48 * n);
    }
}
