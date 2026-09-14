// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RebalancerBase} from "./RebalancerBase.t.sol";
import {RebalancerHandler} from "./RebalancerHandler.t.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {MockProvider} from "../mocks/MockProvider.sol";

/**
 * @title RebalancerInvariantsTest
 * @notice Property-based / invariant coverage for the Rebalancer vault, driven by
 *         `RebalancerHandler`'s bounded fuzz entry points. No RPC/fork dependency.
 */
contract RebalancerInvariantsTest is StdInvariant, RebalancerBase {
    RebalancerHandler public handler;

    uint256 internal _lastHighWaterMark;

    function setUp() public override {
        super.setUp();

        // Give the reference holder a real, standing position that the handler will never
        // touch, so we can assert its value is never diluted by other actors' activity.
        _executeDeposit(vault, HUNDRED, referenceHolder);
        uint256 referenceShares = vault.balanceOf(referenceHolder);

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;

        MockYieldSource[] memory sourcesArr = new MockYieldSource[](3);
        sourcesArr[0] = sourceA;
        sourcesArr[1] = sourceB;
        sourcesArr[2] = sourceC;

        MockProvider[] memory providersArr = new MockProvider[](3);
        providersArr[0] = providerA;
        providersArr[1] = providerB;
        providersArr[2] = providerC;

        handler = new RebalancerHandler(
            vault,
            asset,
            sourcesArr,
            providersArr,
            actors,
            referenceHolder,
            referenceShares
        );

        // rebalance() is EXECUTOR_ROLE-gated; the handler calls it as itself.
        vault.grantRole(vault.EXECUTOR_ROLE(), address(handler));

        // Nonzero fees (post-init, via the admin-role setters) so `handler_applyFees`
        // (combined with `handler_warpTime`) actually exercises fee-share minting and the
        // high-water-mark ratchet under fuzzing, not just the zero-fee no-op path.
        vault.setPerformanceFee(0.1e18); // 10%, within MAX_PERFORMANCE_FEE (20%)
        vault.setManagementFee(0.02e18); // 2%, within MAX_MANAGEMENT_FEE (5%)

        _lastHighWaterMark = vault.getHighWaterMark();

        targetContract(address(handler));
    }

    /// @notice The performance-fee high-water mark (Finding 6) must never decrease. It
    /// only ever ratchets up inside `_applyFees()` — regardless of deposits, withdrawals,
    /// mints, redeems, rebalances, or even losses (a loss just means the share price sits
    /// below the mark until it recovers; the mark itself never moves down).
    function invariant_HighWaterMarkNeverDecreases() public {
        uint256 current = vault.getHighWaterMark();
        assertGe(current, _lastHighWaterMark, "high-water mark decreased");
        _lastHighWaterMark = current;
    }

    /// @notice A holder who never interacts with the vault themselves must never see
    /// `convertToAssets(shares)` decrease purely because some OTHER actor deposited,
    /// minted, withdrew, redeemed, rebalanced, or applied fees. Enforced call-by-call in
    /// `RebalancerHandler.trackReferenceValue`; this invariant just asserts the running
    /// violation counter never moves off zero. Genuine yield/loss events and provider
    /// revert-toggles are intentionally excluded from that check, since those are expected
    /// to move share price in either direction for everyone, reference holder included.
    function invariant_ReferenceHolderNeverDilutedByOthers() public view {
        assertEq(
            handler.ghost_referenceValueDecreaseViolations(),
            0,
            "reference holder's convertToAssets() was diluted by another actor's action"
        );
    }

    /// @notice `totalAssets()` must never revert, and must always equal exactly the sum of
    /// currently-healthy providers' balances, regardless of how many providers have been
    /// toggled into a `getDepositBalance`-reverting state (Finding 2).
    function invariant_TotalAssetsDegradesGracefully() public view {
        uint256 total = vault.totalAssets();

        (, uint256[] memory balances, bool[] memory oks) = vault
            .getProviderBalances();
        uint256 expected;
        for (uint256 i; i < balances.length; i++) {
            if (oks[i]) expected += balances[i];
        }
        assertEq(
            total,
            expected,
            "totalAssets() diverged from the sum of healthy providers"
        );
    }

    /// @dev Foundry calls `afterInvariant()` exactly once at the end of each invariant run
    /// (i.e. after the full random call sequence), unlike `invariant_*` functions, which
    /// run after EVERY call including the zeroth (before any fuzzing has happened) — this
    /// sanity check would spuriously fail immediately at call 0 if written as an
    /// `invariant_*` function instead.
    /// @notice Sanity check that the fuzzer actually exercised the interesting paths, so a
    /// passing run can't be a silent no-op (e.g. every call reverting immediately).
    function afterInvariant() public view {
        assertGt(
            handler.ghost_depositCalls(),
            0,
            "fuzzer never completed a single successful deposit"
        );
        assertGt(
            handler.ghost_applyFeesCalls(),
            0,
            "fuzzer never completed a single successful applyFees() call"
        );
    }
}
