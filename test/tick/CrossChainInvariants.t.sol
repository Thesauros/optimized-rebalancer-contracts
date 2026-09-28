// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {TickFixture} from "./TickFixture.sol";
import {ITickAccountant} from "../../contracts/tick/interfaces/ITickAccountant.sol";
import {IEpochVault} from "../../contracts/tick/interfaces/IEpochVault.sol";
import {ChainAgent} from "../../contracts/crosschain/ChainAgent.sol";
import {MockBridgeHub} from "./mocks/MockBridge.sol";

/**
 * @notice Drives the whole two-chain system only through public entry points
 *         with real token movement (the mock bridge holds tokens in flight).
 *         Ghost variables track every token that enters or leaves the system.
 */
contract CrossChainHandler is TickFixture {
    address[3] internal actors;
    uint256[] internal openRequests;

    // ghosts
    uint256 public ghostIn; // seed + deposits + yield
    uint256 public ghostOut; // paid to users + losses + refunded cancels
    uint64 public ghostMaxTickId;
    bool public ghostTickRegressed;
    bool public ghostOverpaidRedeem;
    uint256 public ghostClaims;
    uint256 public ghostRedeemClears;
    uint256 public ghostDepositClears;
    uint256 public ghostDeliveries;
    uint256 public ghostBridges;
    uint256 public ghostInstants;
    mapping(uint256 => uint256) public claimCount;

    function init() external {
        setUp();
        actors = [alice, bob, carol];
        ghostIn = SEED + 1 + 1; // vault seed + two strategy seeds
        wire.setFeeBps(2);
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, ONE, 200_000 * ONE);
        address who = actors[actorSeed % 3];
        openRequests.push(_requestDeposit(who, amount));
        ghostIn += amount;
    }

    function redeem(uint256 actorSeed, uint256 bps) external {
        address who = actors[actorSeed % 3];
        uint256 shares = (vault.balanceOf(who) * bound(bps, 1, 10_000)) / 10_000;
        if (shares == 0) return;
        openRequests.push(_requestRedeem(who, shares));
    }

    function cancelLatest() external {
        // the newest request the contract would actually accept: anything in the
        // open epoch, plus a deposit in a closed epoch that is not cleared yet.
        // Bounded scan, because openRequests only ever grows.
        uint256 n = openRequests.length;
        uint256 floor = n > 32 ? n - 32 : 0;
        for (uint256 i = n; i > floor; i--) {
            uint256 id = openRequests[i - 1];
            IEpochVault.Request memory r = vault.getRequest(id);
            if (r.status != IEpochVault.RequestStatus.Requested) continue;
            if (r.epoch != vault.currentEpoch()) {
                if (r.kind != IEpochVault.RequestKind.Deposit) continue;
                if (vault.getEpoch(r.epoch).depositsCleared) continue;
            }
            vm.prank(r.owner);
            vault.cancel(id);
            if (r.kind == IEpochVault.RequestKind.Deposit) ghostOut += r.amount;
            return;
        }
    }

    function tick(uint256 dt) external {
        _advance(bound(dt, 60, 3 hours));
        (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSelector(this.tryTick.selector));
        ok;
        ret;
        uint64 last = accountant.lastTickId();
        if (last < ghostMaxTickId) ghostTickRegressed = true;
        ghostMaxTickId = last;
    }

    function tryTick() external {
        require(msg.sender == address(this));
        _tick();
    }

    function closeAndClear() external {
        try vault.closeEpoch() {} catch {}
        _advance(60);
        try this.tryTick() {} catch {}
        _advance(1);
        (, uint64 nextRedeem,) = vault.cursors();
        (uint64 nextDeposit,,) = vault.cursors();
        try vault.clearDeposits() {
            if (vault.getEpoch(nextDeposit).depositAssets != 0) ghostDepositClears++;
        } catch {}
        try vault.clearRedeems() {
            IEpochVault.Epoch memory e = vault.getEpoch(nextRedeem);
            if (e.redeemShares != 0) {
                ghostRedeemClears++;
                ITickAccountant.Tick memory t = accountant.getTick(e.redeemTickId);
                if (e.priceRedeem > t.rateBid || e.priceRedeem > e.openRateBid) ghostOverpaidRedeem = true;
            }
        } catch {}
    }

    function claimAll() external {
        uint256 n = openRequests.length;
        for (uint256 i; i < n; i++) {
            uint256 id = openRequests[i];
            IEpochVault.Request memory r = vault.getRequest(id);
            if (r.status != IEpochVault.RequestStatus.Requested) continue;
            uint256 before = usdc.balanceOf(r.receiver);
            try vault.claim(id) {
                claimCount[id]++;
                ghostClaims++;
                if (r.kind == IEpochVault.RequestKind.Redeem) {
                    ghostOut += usdc.balanceOf(r.receiver) - before;
                }
            } catch {}
        }
    }

    function instant(uint256 actorSeed, uint256 bps) external {
        address who = actors[actorSeed % 3];
        uint256 shares = (vault.balanceOf(who) * bound(bps, 1, 2_000)) / 10_000;
        if (shares == 0) return;
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        try vault.instantRedeem(shares, who, who, 0) {
            ghostInstants++;
            ghostOut += usdc.balanceOf(who) - before;
        } catch {}
    }

    function push(uint256 amount) external {
        amount = bound(amount, 1, 500_000 * ONE);
        vm.prank(executor);
        try vault.pushToAgent(amount) {} catch {}
    }

    function recall(uint256 amount) external {
        uint256 idle = usdc.balanceOf(address(hubAgent));
        if (idle == 0) return;
        amount = bound(amount, 1, idle);
        vm.prank(executor);
        hubAgent.returnToVault(amount);
    }

    function allocate(bool onSpoke, uint256 amount) external {
        ChainAgent a = onSpoke ? spokeAgent : hubAgent;
        uint256 idle = usdc.balanceOf(address(a));
        if (idle < 1) return;
        amount = bound(amount, 1, idle);
        vm.prank(executor);
        try a.allocate(amount) {} catch {}
    }

    function deallocate(bool onSpoke, uint256 bps) external {
        ChainAgent a = onSpoke ? spokeAgent : hubAgent;
        uint256 shares = (a.strategyShares() * bound(bps, 1, 10_000)) / 10_000;
        if (shares == 0) return;
        vm.prank(executor);
        // minAssets 0: the handler injects yield and losses, so a floor here would
        // make the action revert on legitimate price movement rather than explore
        a.deallocateShares(shares, 0);
    }

    function bridge(bool fromSpoke, uint256 amount) external {
        ChainAgent a = fromSpoke ? spokeAgent : hubAgent;
        uint256 idle = usdc.balanceOf(address(a));
        if (idle < 100) return;
        amount = bound(amount, 100, idle);
        uint256 minReceive = (amount * 9_950 + 9_999) / 10_000;
        if (fromSpoke) {
            vm.chainId(SPOKE);
            vm.prank(executor);
            try spokeAgent.bridgeOut(ROUTE_TO_HUB, amount, minReceive, bytes32(0)) returns (bytes32 id) {
                ghostBridges++;
                _trackTransfer(id, SPOKE);
            } catch {}
            vm.chainId(HUB);
        } else {
            vm.prank(executor);
            try hubAgent.bridgeOut(ROUTE_TO_SPOKE, amount, minReceive, bytes32(0)) returns (bytes32 id) {
                ghostBridges++;
                _trackTransfer(id, HUB);
            } catch {}
        }
    }

    function deliver(uint256 indexSeed) external {
        uint256 n = wire.count();
        if (n == 0) return;
        uint256 index = indexSeed % n;
        MockBridgeHub.Message memory m = wire.message(index);
        if (m.delivered) return;
        // the bridge fee stays on the wire, which is inside the counted system
        if (m.dstAgent == address(spokeAgent)) _deliverToSpoke(index);
        else _deliverToHub(index);
        ghostDeliveries++;
    }

    function yieldOrLoss(bool onSpoke, uint256 amount, bool loss) external {
        address strategy = onSpoke ? address(spokeStrategy) : address(hubStrategy);
        uint256 held = (onSpoke ? spokeSource : hubSource).balanceOf(strategy);
        if (held < 1_000) return;
        amount = bound(amount, 1, held / 2_000); // <= 0.05% per call
        if (loss) {
            _loss(onSpoke ? spokeSource : hubSource, strategy, amount);
            ghostOut += amount;
        } else {
            _yield(onSpoke ? spokeSource : hubSource, strategy, amount);
            ghostIn += amount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           VIEWS FOR INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function systemAssets() external view returns (uint256) {
        return _hubSystemAssets();
    }

    function wireInFlight() external view returns (uint256 total) {
        uint256 n = wire.count();
        for (uint256 i; i < n; i++) {
            MockBridgeHub.Message memory m = wire.message(i);
            if (!m.delivered) total += m.amount;
        }
    }

    function transferStatesConsistent() external view returns (bool) {
        for (uint256 i; i < trackedTransfers.length; i++) {
            bytes32 id = trackedTransfers[i];
            bool fromHub = transferSrc[id] == HUB;
            ChainAgent src = fromHub ? hubAgent : spokeAgent;
            ChainAgent dst = fromHub ? spokeAgent : hubAgent;
            if (src.getSent(id).sentAt == 0) return false; // recorded at the source
            if (src.getReceived(id).receivedAt != 0) return false; // never "received" at its own source
            ChainAgent.Received memory r = dst.getReceived(id);
            if (r.receivedAt != 0 && r.amount > src.getSent(id).amount) return false;
        }
        return true;
    }

    function requestCount() external view returns (uint256) {
        return openRequests.length;
    }

    function requestAt(uint256 i) external view returns (uint256) {
        return openRequests[i];
    }

    function vaultAddr() external view returns (address) {
        return address(vault);
    }

    function wireAddr() external view returns (address) {
        return address(wire);
    }
}

contract CrossChainInvariantsTest is Test {
    CrossChainHandler internal h;

    function setUp() public {
        h = new CrossChainHandler();
        h.init();
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = h.deposit.selector;
        selectors[1] = h.redeem.selector;
        selectors[2] = h.cancelLatest.selector;
        selectors[3] = h.tick.selector;
        selectors[4] = h.closeAndClear.selector;
        selectors[5] = h.claimAll.selector;
        selectors[6] = h.instant.selector;
        selectors[7] = h.push.selector;
        selectors[8] = h.recall.selector;
        selectors[9] = h.allocate.selector;
        selectors[10] = h.deallocate.selector;
        selectors[11] = h.bridge.selector;
        selectors[12] = h.deliver.selector;
        selectors[13] = h.yieldOrLoss.selector;
        // uniformly weighted: `closeAndClear` was listed twice, which silently gave
        // the epoch lifecycle double the sampling of every other action
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
        targetContract(address(h));
    }

    /// @dev Conservation: every token is either in the system or accounted as out.
    function invariant_conservation() public view {
        assertEq(h.systemAssets() + h.ghostOut(), h.ghostIn(), "tokens created or destroyed");
    }

    /// @dev Invariant 1: the vault's cash ledger is backed and covers what it owes.
    function invariant_vaultSolvency() public view {
        IEpochVaultView v = IEpochVaultView(h.vaultAddr());
        (uint256 cash, uint256 pending,, uint256 reserved,,) = v.accounting();
        assertGe(cash, pending + reserved, "cash < pending + reserved");
        assertGe(IERC20View(v.asset()).balanceOf(address(v)), cash, "ledger above real balance");
    }

    /// @dev Invariant 3: tokens physically on the wire equal undelivered transfers,
    ///      and no transfer is in two states.
    function invariant_singleState() public view {
        IEpochVaultView v = IEpochVaultView(h.vaultAddr());
        assertTrue(h.transferStatesConsistent(), "transfer in two states");
        // the wire holds exactly the in-flight principal plus fees already retained
        assertGe(IERC20View(v.asset()).balanceOf(h.wireAddr()), h.wireInFlight(), "wire short");
    }

    /// @dev Invariants 4 and 1b: tick ids never regress; no redemption priced above bid.
    function invariant_ticksAndPricing() public view {
        assertFalse(h.ghostTickRegressed(), "tick id regressed");
        assertFalse(h.ghostOverpaidRedeem(), "redeem priced above bid or open rate");
    }

    /// @dev Invariant 13: the vault's own share balance is exactly seed + escrow + unclaimed.
    function invariant_shareBookkeeping() public view {
        IEpochVaultView v = IEpochVaultView(h.vaultAddr());
        (,,,, uint256 escrow, uint256 unclaimed) = v.accounting();
        assertEq(v.balanceOf(address(v)), 1e6 + escrow + unclaimed, "vault share balance drift");
    }

    /// @dev Evidence that the run exercised the system rather than no-ops.
    function afterInvariant() public view {
        console.log("ticks", uint256(h.ghostMaxTickId()), "claims", h.ghostClaims());
        console.log("depositClears", h.ghostDepositClears(), "redeemClears", h.ghostRedeemClears());
        console.log("bridges", h.ghostBridges(), "deliveries", h.ghostDeliveries());
        console.log("instants", h.ghostInstants());
    }

    /// @dev Invariant 12: each request is claimed at most once.
    function invariant_claimOnce() public view {
        uint256 n = h.requestCount();
        for (uint256 i; i < n; i++) {
            assertLe(h.claimCount(h.requestAt(i)), 1, "claimed twice");
        }
    }
}

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
}

interface IEpochVaultView {
    function accounting() external view returns (uint256, uint256, uint256, uint256, uint256, uint256);
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
}
