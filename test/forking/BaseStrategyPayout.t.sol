// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BaseStrategyExpansionForkTest} from "./BaseStrategyExpansion.t.sol";
import {ChainAgent} from "../../contracts/crosschain/ChainAgent.sol";
import {EpochVault} from "../../contracts/tick/EpochVault.sol";
import {TickAccountant} from "../../contracts/tick/TickAccountant.sol";
import {NavSnapshot} from "../../contracts/tick/NavSnapshot.sol";
import {IEpochVaultAccounting} from "../../contracts/tick/interfaces/IEpochVaultAccounting.sol";
import {IEpochVault} from "../../contracts/tick/interfaces/IEpochVault.sol";
import {ITickAccountant} from "../../contracts/tick/interfaces/ITickAccountant.sol";

/// @notice Actual Base hub payout after registration, with an explicitly modeled remote NAV.
/// @dev The remote position is a fixed-price test input, not a re-derivation of Arbitrum.
/// Uses the real accountant's authorized commit path and preserves freshness/risk checks.
contract BaseStrategyPayoutForkTest is BaseStrategyExpansionForkTest {
    address internal constant VAULT = 0x33c4F5Efc49DCEa72bfA8Fe62e5Cb7B3226d7cB6;
    address internal constant ACCOUNTANT = 0xB45819B6844708915c5d7936A847186A6a078b27;
    address internal constant REMOTE_AGENT = 0x10DaB1A9BB794A53849D295fF08768345888Ddd9;

    function _commitModeledRemoteTick() internal {
        EpochVault vault = EpochVault(VAULT);
        TickAccountant accountant = TickAccountant(ACCOUNTANT);
        (, ITickAccountant.Tick memory previous) = accountant.latestAccepted();
        uint256 index = vault.checkpointCount() - 1;
        IEpochVaultAccounting.Checkpoint memory cp = vault.checkpointAt(index);
        uint256 hubIdle = usdc.balanceOf(AGENT);
        uint256 hubShares = strategy.balanceOf(AGENT);
        uint256 hubValue = strategy.convertToAssets(hubShares);

        // Model unchanged total PPS to isolate payout plumbing from remote valuation.
        // Actual Base holdings are priced by the upgraded seven-provider Strategy.
        uint256 targetNav = uint256(cp.totalSupply) * previous.rateBid / 1e18;
        uint256 gross = targetNav + cp.pendingDeposits + cp.liabilities;
        assertGt(gross, uint256(cp.cash) + hubIdle + hubValue, "fixture has remote capital");
        uint256 remoteValue = gross - cp.cash - hubIdle - hubValue;

        NavSnapshot.Snapshot memory s;
        s.version = 1;
        s.tickId = accountant.lastTickId() + 1;
        s.referenceTime = uint64(block.timestamp);
        s.chains = new NavSnapshot.ChainRef[](2);
        uint64 referenceBlock = uint64(block.number);
        bytes32 simulatedHash = keccak256(abi.encode("local Base payout simulation", referenceBlock, block.timestamp));
        vm.roll(block.number + 1);
        vm.setBlockhash(referenceBlock, simulatedHash);
        s.chains[0] = NavSnapshot.ChainRef(8453, referenceBlock, simulatedHash);
        s.chains[1] = NavSnapshot.ChainRef(42161, 1, keccak256("modeled remote reference"));
        s.positions = new NavSnapshot.Position[](3);
        s.positions[0] = NavSnapshot.Position(8453, AGENT, address(0), 0, hubIdle, hubIdle, hubIdle);
        s.positions[1] = NavSnapshot.Position(8453, AGENT, STRATEGY, 1, hubShares, hubValue, hubValue);
        s.positions[2] = NavSnapshot.Position(42161, REMOTE_AGENT, address(0), 0, remoteValue, remoteValue, remoteValue);
        s.inFlight = new NavSnapshot.InFlight[](0);
        s.hubCash = cp.cash;
        s.pendingDeposits = cp.pendingDeposits;
        s.liabilities = cp.liabilities;
        s.totalShares = cp.totalSupply;
        assertTrue(accountant.hasRole(accountant.NAV_UPDATER_ROLE(), governance));
        vm.prank(governance);
        accountant.commitTick(s, index);
        assertEq(uint8(accountant.getTick(s.tickId).status), uint8(ITickAccountant.TickStatus.Accepted));
        assertFalse(accountant.frozen());
        assertFalse(accountant.quarantined());
    }

    function testSevenProviderHubPushAndRealHolderPayoutWithModeledRemoteNav() public {
        _upgrade();
        _register();
        // Fund both new sources on the isolated fork; old holder shares are unchanged.
        _deposit(100e6);
        _move(original[0], fluid, 10e6);
        _move(original[0], v2, 10e6);
        EpochVault vault = EpochVault(VAULT);
        ChainAgent agent = ChainAgent(AGENT);
        address holder;
        if (vault.balanceOf(governance) >= 500_000) holder = governance;
        for (uint256 i = 1; holder == address(0) && i <= 8; ++i) {
            IEpochVault.Request memory request = vault.getRequest(i);
            if (vault.balanceOf(request.receiver) >= 500_000) holder = request.receiver;
            else if (vault.balanceOf(request.owner) >= 500_000) holder = request.owner;
        }
        assertTrue(holder != address(0), "existing real vault holder");
        // The real 24h governance wait makes the existing Tick stale. This gate
        // stays enforced for instant exits until a new authorized Tick is accepted.
        vm.expectRevert(IEpochVault.TickNotUsable.selector);
        vm.prank(holder);
        vault.instantRedeem(500_000, holder, holder, 1);

        _commitModeledRemoteTick();
        uint256 agentSharesBefore = strategy.balanceOf(AGENT);
        uint256 vaultCashBefore = usdc.balanceOf(VAULT);
        vm.startPrank(governance);
        agent.deallocate(2e6);
        agent.returnToVault(2e6);
        vault.pushToAgent(1e6);
        agent.allocate(1e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(VAULT), vaultCashBefore + 1e6);
        assertLt(strategy.balanceOf(AGENT), agentSharesBefore, "net recall belongs to vault cash");
        uint256 holderAssets = usdc.balanceOf(holder);
        uint256 holderShares = vault.balanceOf(holder);
        vm.prank(holder);
        uint256 paid = vault.instantRedeem(500_000, holder, holder, 1);
        assertGt(paid, 0);
        assertEq(usdc.balanceOf(holder) - holderAssets, paid);
        assertEq(holderShares - vault.balanceOf(holder), 500_000);
        assertEq(vaultCashBefore + 1e6 - usdc.balanceOf(VAULT), paid);
        assertTrue(strategy.providersHealthy());
    }
}
