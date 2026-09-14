// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockProvider} from "../mocks/MockProvider.sol";

/**
 * @title RebalancerHandler
 * @notice Bounded fuzz entry points for the Rebalancer invariant suite.
 * @dev Every action that touches the vault is wrapped in try/catch: a legitimately
 *      reverting call (insufficient balance, a paused action, a degraded provider, ...)
 *      must never abort the fuzzing campaign. Only a genuine invariant violation — an
 *      `assert*` failure here or in `RebalancerInvariants.t.sol` — should ever stop a run.
 *      Ghost variables below let the invariant tests assert on cumulative
 *      activity/outcomes across the whole random call sequence.
 */
contract RebalancerHandler is Test {
    Rebalancer public immutable vault;
    MockERC20 public immutable asset;

    MockYieldSource[] public sources;
    MockProvider[] public providers;
    address[] public actors;

    /// @dev A holder the handler never acts as/for. Its shares are fixed by the deploying
    /// test before this handler is wired in, so `vault.convertToAssets(referenceShares)`
    /// isolates the effect of every OTHER actor's activity on an uninvolved third party.
    address public immutable referenceHolder;
    uint256 public immutable referenceShares;

    // ---------------------------------------------------------------------
    // Ghost variables
    // ---------------------------------------------------------------------
    uint256 public ghost_sumDeposited;
    uint256 public ghost_sumWithdrawn;
    uint256 public ghost_sumYield;
    uint256 public ghost_sumLoss;

    uint256 public ghost_depositCalls;
    uint256 public ghost_mintCalls;
    uint256 public ghost_withdrawCalls;
    uint256 public ghost_redeemCalls;
    uint256 public ghost_rebalanceCalls;
    uint256 public ghost_applyFeesCalls;
    uint256 public ghost_yieldCalls;
    uint256 public ghost_lossCalls;
    uint256 public ghost_toggleCalls;

    /// @dev Incremented whenever `vault.convertToAssets(referenceShares)` is observed to
    /// drop immediately around a deposit/mint/withdraw/redeem/rebalance/applyFees call made
    /// by someone other than `referenceHolder`. Should stay 0 for the entire campaign;
    /// asserted by `RebalancerInvariants.invariant_ReferenceHolderNeverDilutedByOthers`.
    uint256 public ghost_referenceValueDecreaseViolations;

    constructor(
        Rebalancer vault_,
        MockERC20 asset_,
        MockYieldSource[] memory sources_,
        MockProvider[] memory providers_,
        address[] memory actors_,
        address referenceHolder_,
        uint256 referenceShares_
    ) {
        vault = vault_;
        asset = asset_;
        for (uint256 i; i < sources_.length; i++) {
            sources.push(sources_[i]);
        }
        for (uint256 i; i < providers_.length; i++) {
            providers.push(providers_[i]);
        }
        actors = actors_;
        referenceHolder = referenceHolder_;
        referenceShares = referenceShares_;
    }

    /// @dev Wraps actions that must never dilute an uninvolved holder. Excluded on purpose
    /// from `handler_simulateYield`/`handler_simulateLoss` (genuine, expected value moves
    /// in either direction) and `handler_toggleProviderRevert` (a provider going dark is,
    /// from the vault's own accounting, indistinguishable from a temporary loss).
    /// @dev Only asserted while every provider's `getDepositBalance` is currently healthy.
    /// When one provider is toggled into a reverting state, deposits can still land at it
    /// (its `deposit()`/write path is untouched by the toggle) while it is simultaneously
    /// invisible to `totalAssets()` (Finding 2's `_safeGetDepositBalance`) — new shares get
    /// minted against a temporarily under-counted price, which *does* transiently reduce
    /// convertToAssets() for everyone, reference holder included. That is an accepted,
    /// narrow consequence of degrading gracefully instead of halting the vault outright
    /// (and is exactly what `invariant_TotalAssetsDegradesGracefully` separately covers,
    /// deliberately) — not the rounding-direction fairness property this check targets.
    modifier trackReferenceValue() {
        bool healthy = _allProvidersHealthy();
        uint256 before = vault.convertToAssets(referenceShares);
        _;
        if (healthy && _allProvidersHealthy()) {
            uint256 afterValue = vault.convertToAssets(referenceShares);
            if (afterValue < before) {
                ghost_referenceValueDecreaseViolations++;
            }
        }
    }

    function _allProvidersHealthy() internal view returns (bool) {
        for (uint256 i; i < sources.length; i++) {
            if (sources[i].shouldRevertOnGetBalance()) return false;
        }
        return true;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function handler_deposit(
        uint256 actorSeed,
        uint256 amount
    ) external trackReferenceValue {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, MILLION());

        asset.mint(actor, amount);
        vm.startPrank(actor);
        asset.approve(address(vault), amount);
        try vault.deposit(amount, actor) {
            ghost_sumDeposited += amount;
            ghost_depositCalls++;
        } catch {
            // legitimate revert (e.g. below minAssets, paused) — swallow and continue
        }
        vm.stopPrank();
    }

    function handler_mint(
        uint256 actorSeed,
        uint256 shares
    ) external trackReferenceValue {
        address actor = _actor(actorSeed);
        shares = bound(shares, 1, MILLION());

        uint256 previewed = vault.previewMint(shares);
        if (previewed == 0) return;

        asset.mint(actor, previewed);
        vm.startPrank(actor);
        asset.approve(address(vault), previewed);
        try vault.mint(shares, actor) returns (uint256 assets) {
            ghost_sumDeposited += assets;
            ghost_mintCalls++;
        } catch {}
        vm.stopPrank();
    }

    function handler_withdraw(
        uint256 actorSeed,
        uint256 amount
    ) external trackReferenceValue {
        address actor = _actor(actorSeed);
        uint256 maxAssets = vault.convertToAssets(vault.balanceOf(actor));
        if (maxAssets == 0) return;
        amount = bound(amount, 1, maxAssets);

        vm.startPrank(actor);
        try vault.withdraw(amount, actor, actor) {
            ghost_sumWithdrawn += amount;
            ghost_withdrawCalls++;
        } catch {
            // e.g. InsufficientLiquidity if providers were toggled to fail
        }
        vm.stopPrank();
    }

    function handler_redeem(
        uint256 actorSeed,
        uint256 shares
    ) external trackReferenceValue {
        address actor = _actor(actorSeed);
        uint256 maxShares = vault.balanceOf(actor);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);

        vm.startPrank(actor);
        try vault.redeem(shares, actor, actor) returns (uint256 assets) {
            ghost_sumWithdrawn += assets;
            ghost_redeemCalls++;
        } catch {}
        vm.stopPrank();
    }

    function handler_simulateYield(uint256 sourceSeed, uint256 amount) external {
        amount = bound(amount, 1, 100_000e6);
        MockYieldSource src = sources[sourceSeed % sources.length];

        asset.mint(address(this), amount);
        asset.approve(address(src), amount);
        try src.simulateYield(address(vault), amount) {
            ghost_sumYield += amount;
            ghost_yieldCalls++;
        } catch {}
    }

    /// @notice Advances time by a bounded amount so time-based management-fee accrual
    /// (`_accruedFees`'s `dt`) is actually exercised by the fuzzer, instead of every call
    /// happening at the same block.timestamp.
    function handler_warpTime(uint256 secondsSeed) external {
        uint256 delta = bound(secondsSeed, 0, 60 days);
        if (delta == 0) return;
        vm.warp(block.timestamp + delta);
    }

    function handler_simulateLoss(uint256 sourceSeed, uint256 amount) external {
        MockYieldSource src = sources[sourceSeed % sources.length];
        uint256 bal = src.balances(address(vault));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        try src.simulateLoss(address(vault), amount) {
            ghost_sumLoss += amount;
            ghost_lossCalls++;
        } catch {}
    }

    function handler_applyFees() external trackReferenceValue {
        try vault.applyFees() {
            ghost_applyFeesCalls++;
        } catch {}
    }

    /// @notice Flips whether one provider's `getDepositBalance()` view call reverts,
    /// exercising the Finding 2 graceful-degradation path from `totalAssets()`/
    /// `_withdraw()`/`rebalance()`.
    function handler_toggleProviderRevert(uint256 providerSeed) external {
        MockYieldSource src = sources[providerSeed % sources.length];
        bool newState = !src.shouldRevertOnGetBalance();
        src.setShouldRevertOnGetBalance(newState);
        ghost_toggleCalls++;
    }

    function handler_rebalance(
        uint256 fromSeed,
        uint256 toSeed,
        uint256 amountSeed
    ) external trackReferenceValue {
        uint256 count = providers.length;
        IProvider from = providers[fromSeed % count];
        IProvider to = providers[toSeed % count];
        if (address(from) == address(to)) return;

        uint256 assetsAtFrom;
        try from.getDepositBalance(address(vault), vault) returns (
            uint256 bal
        ) {
            assetsAtFrom = bal;
        } catch {
            return;
        }
        if (assetsAtFrom == 0) return;

        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory sourcesArr = new IProvider[](1);
        IProvider[] memory destsArr = new IProvider[](1);
        amounts[0] = bound(amountSeed, 1, assetsAtFrom);
        sourcesArr[0] = from;
        destsArr[0] = to;

        try vault.rebalance(amounts, sourcesArr, destsArr) {
            ghost_rebalanceCalls++;
        } catch {}
    }

    // MILLION as a function (not a constant) to keep this handler self-contained without
    // importing the base test's constants contract.
    function MILLION() internal pure returns (uint256) {
        return 1_000_000e6;
    }
}
