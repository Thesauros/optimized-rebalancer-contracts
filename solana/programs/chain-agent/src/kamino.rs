//! Kamino reserve lending adapter. Offsets follow the pinned klend SDK layout;
//! no obligation, borrowing, user-supplied executable or destination is allowed.
use crate::{AgentError, Strategy};
use anchor_lang::prelude::*;
mod wide {
    uint::construct_uint! { pub struct U256(4); }
}
use wide::U256;

pub const PROGRAM: Pubkey = pubkey!("KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD");
pub const DEPOSIT: [u8; 8] = [169, 201, 30, 126, 6, 205, 102, 68];
pub const REDEEM: [u8; 8] = [234, 117, 181, 125, 185, 142, 220, 29];
pub const REFRESH: [u8; 8] = [2, 218, 138, 235, 79, 201, 25, 102];
const RESERVE: [u8; 8] = [43, 242, 204, 202, 26, 247, 59, 127];

fn key(data: &[u8], at: usize) -> Result<Pubkey> {
    Ok(Pubkey::new_from_array(
        data.get(at..at + 32)
            .ok_or(AgentError::ReserveLayout)?
            .try_into()
            .unwrap(),
    ))
}
fn u64_at(data: &[u8], at: usize) -> Result<u64> {
    Ok(u64::from_le_bytes(
        data.get(at..at + 8)
            .ok_or(AgentError::ReserveLayout)?
            .try_into()
            .unwrap(),
    ))
}
fn sf(data: &[u8], at: usize) -> Result<U256> {
    Ok(U256::from_little_endian(
        data.get(at..at + 16).ok_or(AgentError::ReserveLayout)?,
    ))
}

/// Reserve total supply is available + borrowed - protocol/referrer fees.
/// Fraction SF uses 60 fractional bits. Avoid rounding borrowed/fees separately.
pub fn value(data: &[u8], strategy: &Strategy, collateral: u64, slot: u64) -> Result<u64> {
    require!(
        data.len() >= 2600 && data[..8] == RESERVE,
        AgentError::ReserveLayout
    );
    require!(u64_at(data, 8)? == 1, AgentError::ReserveLayout);
    require!(
        u64_at(data, 16)? == slot && data[24] == 0,
        AgentError::StaleReserve
    );
    require_keys_eq!(key(data, 32)?, strategy.market, AgentError::Accounts);
    require_keys_eq!(key(data, 128)?, crate::USDC, AgentError::Accounts);
    require_keys_eq!(
        key(data, 160)?,
        strategy.liquidity_supply,
        AgentError::Accounts
    );
    require_keys_eq!(
        key(data, 2560)?,
        strategy.collateral_mint,
        AgentError::Accounts
    );
    require!(u64_at(data, 272)? == 6, AgentError::Accounts);
    let available = U256::from(u64_at(data, 224)?) << 60;
    let total = available
        .checked_add(sf(data, 232)?)
        .ok_or(AgentError::Arithmetic)?;
    let fees = sf(data, 344)?
        .checked_add(sf(data, 360)?)
        .and_then(|x| x.checked_add(sf(data, 376).ok()?))
        .ok_or(AgentError::Arithmetic)?;
    let net = total.checked_sub(fees).ok_or(AgentError::Arithmetic)?;
    let supply = u64_at(data, 2592)?;
    if collateral == 0 {
        return Ok(0);
    }
    require!(supply > 0, AgentError::ReserveLayout);
    let amount = net
        .checked_mul(U256::from(collateral))
        .ok_or(AgentError::Arithmetic)?
        / U256::from(supply)
        >> 60;
    require!(amount <= U256::from(u64::MAX), AgentError::Arithmetic);
    Ok(amount.as_u64())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn full_width_multiply_prevents_large_reserve_overflow() {
        let net = U256::from(u64::MAX) << 60;
        assert_eq!(
            (net * U256::from(1_000_000u64) / U256::from(u64::MAX) >> 60).as_u64(),
            1_000_000
        );
    }
}
