//! Local-validator-only CPI double. Never deploy this under a production ID.
use solana_program::{
    account_info::AccountInfo,
    entrypoint,
    entrypoint::ProgramResult,
    program::{invoke, invoke_signed},
    program_error::ProgramError,
    pubkey::Pubkey,
    sysvar::{clock::Clock, Sysvar},
};
entrypoint!(process);
fn amount(data: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(data[at..at + 8].try_into().unwrap())
}
fn set(data: &mut [u8], at: usize, n: u64) {
    data[at..at + 8].copy_from_slice(&n.to_le_bytes());
}
fn process(program: &Pubkey, a: &[AccountInfo], data: &[u8]) -> ProgramResult {
    if data == [2, 218, 138, 235, 79, 201, 25, 102] {
        let mut state = a[0].try_borrow_mut_data()?;
        set(&mut state, 16, Clock::get()?.slot);
        state[24] = 0;
        return Ok(());
    }
    let deposit = data.get(..8) == Some(&[169, 201, 30, 126, 6, 205, 102, 68]);
    let redeem = data.get(..8) == Some(&[234, 117, 181, 125, 185, 142, 220, 29]);
    if (!deposit && !redeem) || data.len() != 16 || !a[0].is_signer {
        return Err(ProgramError::InvalidInstructionData);
    }
    let n = amount(data, 8);
    let (market, reserve, auth, liquidity_supply, collateral_mint, user_liquidity, user_collateral) =
        if deposit {
            (&a[2], &a[1], &a[3], &a[5], &a[6], &a[7], &a[8])
        } else {
            (&a[1], &a[2], &a[3], &a[6], &a[5], &a[8], &a[7])
        };
    let (expected, bump) = Pubkey::find_program_address(&[b"lma", market.key.as_ref()], program);
    if expected != *auth.key {
        return Err(ProgramError::InvalidSeeds);
    }
    let seeds: &[&[u8]] = &[b"lma", market.key.as_ref(), &[bump]];
    let (available, supply) = {
        let r = reserve.try_borrow_data()?;
        (amount(&r, 224), amount(&r, 2592))
    };
    let exchange = if available == 0 || supply == 0 {
        1_000_000_000u128
    } else {
        (available as u128) * 1_000_000_000 / (supply as u128)
    };
    let output = if deposit {
        (n as u128) * 1_000_000_000 / exchange
    } else {
        (n as u128) * exchange / 1_000_000_000
    };
    let output = u64::try_from(output).map_err(|_| ProgramError::ArithmeticOverflow)?;
    if deposit {
        invoke(
            &spl_token::instruction::transfer(
                &spl_token::ID,
                user_liquidity.key,
                liquidity_supply.key,
                a[0].key,
                &[],
                n,
            )?,
            &[
                user_liquidity.clone(),
                liquidity_supply.clone(),
                a[0].clone(),
                a[10].clone(),
            ],
        )?;
        invoke_signed(
            &spl_token::instruction::mint_to(
                &spl_token::ID,
                collateral_mint.key,
                user_collateral.key,
                auth.key,
                &[],
                output,
            )?,
            &[
                collateral_mint.clone(),
                user_collateral.clone(),
                auth.clone(),
                a[9].clone(),
            ],
            &[seeds],
        )?;
    } else {
        invoke(
            &spl_token::instruction::burn(
                &spl_token::ID,
                user_collateral.key,
                collateral_mint.key,
                a[0].key,
                &[],
                n,
            )?,
            &[
                user_collateral.clone(),
                collateral_mint.clone(),
                a[0].clone(),
                a[9].clone(),
            ],
        )?;
        invoke_signed(
            &spl_token::instruction::transfer(
                &spl_token::ID,
                liquidity_supply.key,
                user_liquidity.key,
                auth.key,
                &[],
                output,
            )?,
            &[
                liquidity_supply.clone(),
                user_liquidity.clone(),
                auth.clone(),
                a[10].clone(),
            ],
            &[seeds],
        )?;
    }
    let mut r = reserve.try_borrow_mut_data()?;
    set(
        &mut r,
        224,
        if deposit {
            available + n
        } else {
            available - output
        },
    );
    set(
        &mut r,
        2592,
        if deposit { supply + output } else { supply - n },
    );
    r[24] = 1;
    Ok(())
}
