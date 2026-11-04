// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {TickAccountant} from "../../contracts/tick/TickAccountant.sol";
import {EpochVault} from "../../contracts/tick/EpochVault.sol";
import {NavSnapshot} from "../../contracts/tick/NavSnapshot.sol";
import {ITickAccountant} from "../../contracts/tick/interfaces/ITickAccountant.sol";
import {IEpochVault} from "../../contracts/tick/interfaces/IEpochVault.sol";
import {IEpochVaultAccounting} from "../../contracts/tick/interfaces/IEpochVaultAccounting.sol";
import {ChainAgent} from "../../contracts/crosschain/ChainAgent.sol";
import {FeeCapAsset, FeeCapSource, FeeCapProvider} from "../unit/PerformanceFeeCap.t.sol";
import {MockBridgeHub, MockBridgeAdapter} from "./mocks/MockBridge.sol";

/**
 * @title TickFixture
 * @notice Fork-free two-chain stack in one EVM. The hub (Base, 8453) and one
 *         spoke (Arbitrum, 42161) are simulated by switching `block.chainid`.
 *         Strategies are real `Rebalancer` instances over the mock provider from
 *         the fee-cap suite. `_buildSnapshot` is a minimal NAV engine that
 *         follows docs/nav-reproduction.md, so commits in tests are honest
 *         unless a test tampers with the result on purpose.
 */
abstract contract TickFixture is Test {
    uint64 internal constant HUB = 8453;
    uint64 internal constant SPOKE = 42161;
    uint256 internal constant ONE = 1e6;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SEED = 1e6;

    bytes32 internal constant ROUTE_TO_SPOKE = keccak256("hub->spoke");
    bytes32 internal constant ROUTE_TO_HUB = keccak256("spoke->hub");

    address internal admin = makeAddr("admin");
    address internal updater = makeAddr("updater");
    address internal executor = makeAddr("executor");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");

    FeeCapAsset internal usdc;
    TickAccountant internal accountant;
    EpochVault internal vault;

    FeeCapSource internal hubSource;
    FeeCapSource internal spokeSource;
    Rebalancer internal hubStrategy;
    Rebalancer internal spokeStrategy;
    ChainAgent internal hubAgent;
    ChainAgent internal spokeAgent;

    MockBridgeHub internal wire;
    MockBridgeAdapter internal hubAdapter;
    MockBridgeAdapter internal spokeAdapter;

    /// @dev Transfers the test NAV engine treats as possibly in flight.
    bytes32[] internal trackedTransfers;
    mapping(bytes32 => uint64) internal transferSrc;

    function setUp() public virtual {
        vm.chainId(HUB);
        vm.warp(1_800_000_000);
        vm.roll(1_000);

        usdc = new FeeCapAsset();

        accountant = TickAccountant(_proxy(address(new TickAccountant())));
        uint64[] memory chains = new uint64[](2);
        chains[0] = HUB;
        chains[1] = SPOKE;
        accountant.initialize(admin, address(this), treasury, chains, _defaultConfig(), _defaultUp(), _defaultDown());

        vault = EpochVault(_proxy(address(new EpochVault())));
        usdc.mint(address(this), SEED);
        usdc.approve(address(vault), SEED);
        vault.initialize(
            address(usdc),
            "Thesauros Cross-Chain USDC",
            "tcUSDC",
            admin,
            address(this),
            address(accountant),
            SEED,
            _defaultEpochConfig(),
            _defaultLimits()
        );
        vm.prank(admin);
        accountant.setVault(address(vault));

        (hubSource, hubStrategy) = _newStrategy();
        vm.chainId(SPOKE);
        (spokeSource, spokeStrategy) = _newStrategy();
        vm.chainId(HUB);

        hubAgent = ChainAgent(_proxy(address(new ChainAgent())));
        hubAgent.initialize(address(usdc), admin, address(this), address(hubStrategy), address(vault), address(accountant));
        spokeAgent = ChainAgent(_proxy(address(new ChainAgent())));
        spokeAgent.initialize(address(usdc), admin, address(this), address(spokeStrategy), address(0), address(0));

        wire = new MockBridgeHub(IERC20(address(usdc)));
        hubAdapter = new MockBridgeAdapter(address(usdc), address(hubAgent), wire, HUB);
        spokeAdapter = new MockBridgeAdapter(address(usdc), address(spokeAgent), wire, SPOKE);
        hubAdapter.setRemote(SPOKE, address(spokeAdapter));
        spokeAdapter.setRemote(HUB, address(hubAdapter));

        // hub agent: route to spoke, accepts from spoke
        hubAgent.addRoute(ROUTE_TO_SPOKE, address(hubAdapter), SPOKE, address(spokeAgent), 50, uint128(1_000_000 * ONE), uint128(2_000_000 * ONE), uint128(2_000_000 * ONE) / 1 days);
        hubAgent.setPeer(SPOKE, address(spokeAgent), true);
        hubAgent.setAdapter(address(hubAdapter), true);
        // spoke agent (configured while "on" the spoke chain)
        vm.chainId(SPOKE);
        spokeAgent.addRoute(ROUTE_TO_HUB, address(spokeAdapter), HUB, address(hubAgent), 50, uint128(1_000_000 * ONE), uint128(2_000_000 * ONE), uint128(2_000_000 * ONE) / 1 days);
        spokeAgent.setPeer(HUB, address(hubAgent), true);
        spokeAgent.setAdapter(address(spokeAdapter), true);
        vm.chainId(HUB);

        accountant.setAgent(HUB, address(hubAgent), true);
        accountant.setAgent(SPOKE, address(spokeAgent), true);
        vault.setHubAgent(address(hubAgent));

        vm.startPrank(admin);
        accountant.grantRole(accountant.NAV_UPDATER_ROLE(), updater);
        accountant.grantRole(accountant.GUARDIAN_ROLE(), guardian);
        vault.grantRole(vault.EXECUTOR_ROLE(), executor);
        vault.grantRole(vault.GUARDIAN_ROLE(), guardian);
        hubAgent.grantRole(hubAgent.EXECUTOR_ROLE(), executor);
        hubAgent.grantRole(hubAgent.GUARDIAN_ROLE(), guardian);
        spokeAgent.grantRole(spokeAgent.EXECUTOR_ROLE(), executor);
        spokeAgent.grantRole(spokeAgent.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              DEFAULTS
    //////////////////////////////////////////////////////////////*/

    function _defaultConfig() internal pure returns (ITickAccountant.Config memory) {
        return ITickAccountant.Config({
            minTickInterval: 0,
            maxSnapshotAge: 1 hours,
            maxTickAge: 2 hours,
            maxTransit: 1 hours,
            maxSpread: 0.01e18,
            depositClearingMaxDown: 0.001e18,
            maxInFlightRatio: 0.5e18,
            maxOverdueInFlight: type(uint128).max
        });
    }

    /// @dev Up: 0.5% capacity, refill 20% APR. Down: 0.2% capacity, refill 0.1%/day.
    function _defaultUp() internal pure returns (ITickAccountant.Bucket memory) {
        return ITickAccountant.Bucket(0.005e18, uint128(0.2e18) / 365 days, 0, 0);
    }

    function _defaultDown() internal pure returns (ITickAccountant.Bucket memory) {
        return ITickAccountant.Bucket(0.002e18, uint128(0.001e18) / 1 days, 0, 0);
    }

    function _defaultEpochConfig() internal pure returns (IEpochVault.EpochConfig memory) {
        return IEpochVault.EpochConfig({minDuration: 1 hours, maxDuration: 6 hours, minTicks: 1, maxClearingDelay: 1 hours});
    }

    function _defaultLimits() internal pure returns (IEpochVault.Limits memory) {
        return IEpochVault.Limits({
            minDeposit: uint128(ONE),
            maxEpochDeposits: type(uint128).max,
            minimumBuffer: 0,
            minBufferRatio: 0,
            maxInstantWithdrawal: uint128(10_000 * ONE),
            dailyInstantLimit: uint128(50_000 * ONE),
            instantFee: 0.001e18,
            instantMaxTickAge: 2 hours
        });
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _proxy(address impl) internal returns (address) {
        return address(new TransparentUpgradeableProxy(impl, address(this), ""));
    }

    function _newStrategy() internal returns (FeeCapSource source, Rebalancer strategy) {
        source = new FeeCapSource(IERC20(address(usdc)));
        FeeCapProvider provider = new FeeCapProvider(source);
        strategy = Rebalancer(payable(_proxy(address(new Rebalancer()))));
        usdc.mint(address(this), 1);
        usdc.approve(address(strategy), 1);
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = provider;
        strategy.initialize(address(this), address(this), address(usdc), "strategy", "s", providers, treasury, 0, 0, 1);
    }

    /// @dev Moves time and one block forward, so the next commit can bind to the current block.
    function _advance(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
    }

    function _requestDeposit(address who, uint256 assets) internal returns (uint256 id) {
        usdc.mint(who, assets);
        vm.startPrank(who);
        usdc.approve(address(vault), assets);
        id = vault.requestDeposit(assets, who);
        vm.stopPrank();
    }

    function _requestRedeem(address who, uint256 shares) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.requestRedeem(shares, who, who);
    }

    function _yield(FeeCapSource source, address strategy, uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(source), amount);
        source.simulateYield(strategy, amount);
    }

    function _loss(FeeCapSource source, address strategy, uint256 amount) internal {
        source.debitAndSend(strategy, amount, address(0xdead));
    }

    function _trackTransfer(bytes32 id, uint64 srcChain) internal {
        trackedTransfers.push(id);
        transferSrc[id] = srcChain;
    }

    function _bridgeHubToSpoke(uint256 amount, uint256 minReceive) internal returns (bytes32 id, uint256 index) {
        index = wire.count();
        vm.prank(executor);
        id = hubAgent.bridgeOut(ROUTE_TO_SPOKE, amount, minReceive, keccak256("rebalance"));
        _trackTransfer(id, HUB);
    }

    function _bridgeSpokeToHub(uint256 amount, uint256 minReceive) internal returns (bytes32 id, uint256 index) {
        index = wire.count();
        vm.chainId(SPOKE);
        vm.prank(executor);
        id = spokeAgent.bridgeOut(ROUTE_TO_HUB, amount, minReceive, keccak256("rebalance"));
        vm.chainId(HUB);
        _trackTransfer(id, SPOKE);
    }

    function _deliverToSpoke(uint256 index) internal {
        vm.chainId(SPOKE);
        spokeAgent.receiveBridge(address(spokeAdapter), abi.encode(index));
        vm.chainId(HUB);
    }

    function _deliverToHub(uint256 index) internal {
        hubAgent.receiveBridge(address(hubAdapter), abi.encode(index));
    }

    /*//////////////////////////////////////////////////////////////
                         REFERENCE NAV ENGINE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Builds the snapshot at the current block (the hub reference block),
     *      with reference time = now. Both simulated chains share one EVM, so the
     *      cut is trivially consistent here; the cross-EVM cut rule is exercised
     *      off-chain. Call `_commit` in a later block.
     */
    function _buildSnapshot() internal returns (NavSnapshot.Snapshot memory s, uint256 cpIndex) {
        s.version = NavSnapshot.VERSION;
        s.tickId = accountant.lastTickId() + 1;
        s.referenceTime = uint64(block.timestamp);

        bytes32 hubHash = keccak256(abi.encode("block", block.number));
        vm.setBlockhash(block.number, hubHash);
        s.chains = new NavSnapshot.ChainRef[](2);
        s.chains[0] = NavSnapshot.ChainRef(HUB, uint64(block.number), hubHash);
        s.chains[1] = NavSnapshot.ChainRef(SPOKE, uint64(block.number), keccak256("spoke"));

        s.positions = _positions();
        s.inFlight = _inFlight();

        cpIndex = vault.checkpointCount() - 1;
        IEpochVaultAccounting.Checkpoint memory cp = vault.checkpointAt(cpIndex);
        s.hubCash = cp.cash;
        s.pendingDeposits = cp.pendingDeposits;
        s.liabilities = cp.liabilities;
        s.totalShares = cp.totalSupply;
    }

    function _positions() internal view returns (NavSnapshot.Position[] memory out) {
        NavSnapshot.Position[] memory a = _agentPositions(hubAgent, HUB);
        NavSnapshot.Position[] memory b = _agentPositions(spokeAgent, SPOKE);
        out = new NavSnapshot.Position[](a.length + b.length);
        for (uint256 i; i < a.length; i++) out[i] = a[i];
        for (uint256 i; i < b.length; i++) out[a.length + i] = b[i];
    }

    /// @dev Idle first (strategy = 0), then strategy shares: the canonical order.
    function _agentPositions(ChainAgent agent, uint64 chainId) internal view returns (NavSnapshot.Position[] memory out) {
        uint256 idle = usdc.balanceOf(address(agent));
        uint256 shares = agent.strategyShares();
        out = new NavSnapshot.Position[]((idle != 0 ? 1 : 0) + (shares != 0 ? 1 : 0));
        uint256 n;
        if (idle != 0) {
            out[n++] = NavSnapshot.Position(chainId, address(agent), address(0), NavSnapshot.KIND_IDLE, idle, idle, idle);
        }
        if (shares != 0) {
            address strategy = agent.strategy();
            uint256 value = Rebalancer(payable(strategy)).convertToAssets(shares);
            out[n] = NavSnapshot.Position(chainId, address(agent), strategy, NavSnapshot.KIND_STRATEGY_SHARES, shares, value, value);
        }
    }

    function _inFlight() internal view returns (NavSnapshot.InFlight[] memory out) {
        uint256 len = trackedTransfers.length;
        NavSnapshot.InFlight[] memory tmp = new NavSnapshot.InFlight[](len);
        uint256 n;
        for (uint256 i; i < len; i++) {
            (bool pending, NavSnapshot.InFlight memory entry) = _inFlightEntry(trackedTransfers[i]);
            if (pending) tmp[n++] = entry;
        }
        _sortByTransferId(tmp, n);
        out = new NavSnapshot.InFlight[](n);
        for (uint256 i; i < n; i++) out[i] = tmp[i];
    }

    function _inFlightEntry(bytes32 id) internal view returns (bool pending, NavSnapshot.InFlight memory entry) {
        bool fromHub = transferSrc[id] == HUB;
        ChainAgent dst = fromHub ? spokeAgent : hubAgent;
        if (dst.getReceived(id).receivedAt != 0) return (false, entry);
        ChainAgent.Sent memory sent = (fromHub ? hubAgent : spokeAgent).getSent(id);
        entry.transferId = id;
        entry.srcChainId = transferSrc[id];
        entry.dstChainId = sent.dstChainId;
        entry.sentAt = sent.sentAt;
        entry.amountSent = sent.amount;
        entry.minReceive = sent.minReceive;
        entry.writtenDown = sent.writtenDown;
        pending = true;
    }

    function _sortByTransferId(NavSnapshot.InFlight[] memory a, uint256 n) internal pure {
        for (uint256 i = 1; i < n; i++) {
            NavSnapshot.InFlight memory key = a[i];
            uint256 j = i;
            while (j > 0 && uint256(a[j - 1].transferId) > uint256(key.transferId)) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
    }

    /// @dev Snapshot now, commit in the next block.
    function _tick() internal returns (uint64 tickId) {
        (NavSnapshot.Snapshot memory s, uint256 idx) = _buildSnapshot();
        _advance(1);
        vm.prank(updater);
        accountant.commitTick(s, idx);
        return s.tickId;
    }

    function _commit(NavSnapshot.Snapshot memory s, uint256 idx) internal {
        vm.prank(updater);
        accountant.commitTick(s, idx);
    }

    function _lastTick() internal view returns (ITickAccountant.Tick memory t) {
        (, t) = accountant.latestAccepted();
    }

    /// @dev Close the open epoch, tick after cutoff, clear both sides.
    function _cycle() internal returns (uint64 epochId) {
        epochId = vault.currentEpoch();
        _advance(1 hours);
        _tick();
        _advance(1);
        vault.closeEpoch();
        _advance(60);
        _tick();
        _advance(1);
        vault.clearDeposits();
        vault.clearRedeems();
    }

    /// @dev alice deposits `amount` through a full epoch; the executor deploys
    ///      `toStrategy` into the hub strategy and leaves the rest as vault cash.
    function _seedSystem(uint256 amount, uint256 toStrategy) internal returns (uint256 shares) {
        uint256 id = _requestDeposit(alice, amount);
        _cycle();
        shares = vault.claim(id);
        if (toStrategy != 0) {
            vm.prank(executor);
            vault.pushToAgent(toStrategy);
            vm.prank(executor);
            hubAgent.allocate(toStrategy);
        }
        _advance(60);
    }

    function _hubSystemAssets() internal view returns (uint256) {
        return usdc.balanceOf(address(vault)) + usdc.balanceOf(address(hubAgent)) + usdc.balanceOf(address(spokeAgent))
            + usdc.balanceOf(address(wire)) + usdc.balanceOf(address(hubSource)) + usdc.balanceOf(address(spokeSource));
    }
}
