// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IProvider} from "./interfaces/IProvider.sol";

/**
 * @dev Minimal interface exposing only `Rebalancer.initialize()`. Deliberately declared
 *      here instead of importing the concrete `Rebalancer` contract, so `VaultDeployer`
 *      has no compile-time dependency on `Rebalancer`'s implementation and stays reviewable
 *      in isolation. Must be kept in sync with `Rebalancer.initialize()`'s signature.
 */
interface IRebalancerInitializer {
    function initialize(
        address admin_,
        address timelock_,
        address asset_,
        string memory name_,
        string memory symbol_,
        IProvider[] memory providers_,
        address treasury_,
        uint96 managementFee_,
        uint96 performanceFee_,
        uint256 minAssets_
    ) external;
}

/**
 * @title VaultDeployer
 *
 * @notice Deploys a `TransparentUpgradeableProxy` for a `Rebalancer` implementation and
 *         initializes it in the same transaction, closing the proxy front-running window
 *         that previously existed between "deploy proxy" and "call initialize()" being two
 *         separate, mempool-visible transactions.
 *
 * @dev Background: `Rebalancer.initialize()` is guarded only by OpenZeppelin's `initializer`
 *      modifier, i.e. "callable once", not "callable only by the intended deployer". On
 *      2026-08-05, a third party observed a freshly-created, not-yet-initialized
 *      `TransparentUpgradeableProxy` on Arbitrum and called `initialize()` on it ~2 seconds
 *      after creation, before the legitimate deployer's own `initialize()` transaction
 *      landed (see `deploy/deploy-usdc-vault.ts` for the incident note and the previous
 *      "three back-to-back transactions with explicit nonces" mitigation, which reduces but
 *      does not eliminate the race: it still relies on no third party being able to order a
 *      transaction between the deployer's own three).
 *
 *      This contract removes the race entirely by making "create proxy" and "initialize
 *      proxy" a single call stack inside one transaction:
 *        1. Pull the seed deposit (`minAssets_`) from `msg.sender` into this contract
 *           BEFORE the proxy exists. Only `msg.sender`'s own transaction can ever trigger
 *           this pull (it spends `msg.sender`'s own ERC20 allowance to this contract).
 *        2. Deploy the proxy via `new TransparentUpgradeableProxy(implementation,
 *           proxyAdminOwner, "")` with EMPTY constructor data. This is critical: passing
 *           non-empty `initData` into the proxy's constructor would make the proxy attempt
 *           to delegatecall into `initialize()` *during its own construction*, while
 *           `address(this)` (the proxy) has no runtime code yet. `initialize()` ends by
 *           calling `_deposit()`, which delegatecalls a provider (e.g.
 *           `AaveV3Provider.deposit()`, see `contracts/providers/AaveV3Provider.sol:60`),
 *           which calls back `vault.asset()` — a genuine external `CALL`/`STATICCALL` to
 *           `address(this)`. Calling into an address mid-construction (`extcodesize == 0`)
 *           returns empty data, which fails to `abi.decode` as `(address)` and reverts.
 *           This is exactly why the previous deploy script rejected constructor-time
 *           initialization and fell back to the (racy) three-transaction approach.
 *        3. Only AFTER `new TransparentUpgradeableProxy(...)` returns — which in the EVM can
 *           only happen once the proxy's constructor has fully executed and its runtime
 *           code is stored — approve the new proxy to pull `minAssets_`, then call
 *           `initialize(...)` on it as an ordinary external `CALL`. At this point the proxy
 *           has real runtime code, so the `vault.asset()` callback resolves normally against
 *           the delegatecalled `Rebalancer` implementation instead of reverting.
 *
 *      Because steps 1-3 all execute within the internal call stack of a single
 *      `deployAndInitialize` transaction, there is no intermediate, mempool-visible state:
 *      the proxy does not exist before this call creates it, and it is fully initialized
 *      before this call (and therefore the enclosing transaction) returns. A third party can
 *      still call `deployAndInitialize` themselves — but doing so only pulls funds from,
 *      and deploys a proxy owned/administered per the parameters supplied by, THAT caller's
 *      own transaction; they can never observe or race a specific proxy address that isn't
 *      already deployed and initialized by the time any other transaction could see it.
 *
 *      Kept intentionally minimal — no persistent configuration, not upgradeable, no
 *      privileged roles — since it is new, unaudited code whose entire job is
 *      "pull funds, deploy, initialize, emit", and should be trivially reviewable as such.
 *      `Rebalancer.sol` itself is not modified by this fix; the factory pattern requires no
 *      changes to `initialize()` or any other core vault logic.
 */
contract VaultDeployer {
    using SafeERC20 for IERC20;

    /// @dev Thrown when `implementation` or `proxyAdminOwner` is the zero address.
    error VaultDeployer__AddressZero();

    /**
     * @notice Emitted once a vault proxy has been deployed and successfully initialized.
     * @param proxy The address of the newly deployed and initialized vault proxy.
     * @param implementation The `Rebalancer` implementation contract backing the proxy.
     */
    event VaultDeployed(
        address indexed proxy,
        address indexed implementation
    );

    /**
     * @notice Atomically deploys a new `TransparentUpgradeableProxy` for `implementation`
     *         and initializes it, in a single transaction.
     *
     * @param implementation The `Rebalancer` implementation contract to proxy.
     * @param proxyAdminOwner The address that will own the `ProxyAdmin` created internally
     *        by `TransparentUpgradeableProxy` (i.e. who can later upgrade this proxy).
     * @param admin_ The initial `ADMIN_ROLE` holder of the vault.
     * @param timelock_ The timelock contract address for the vault.
     * @param asset_ The ERC20 asset managed by the vault.
     * @param name_ The ERC20 name of the vault's share token.
     * @param symbol_ The ERC20 symbol of the vault's share token.
     * @param providers_ The initial list of providers for the vault (see
     *        `Rebalancer.initialize`; `providers_[0]` becomes the entry provider).
     * @param treasury_ The treasury address that receives fee shares.
     * @param managementFee_ The management fee rate (scaled by `SCALE`, capped at
     *        `MAX_MANAGEMENT_FEE`).
     * @param performanceFee_ The performance fee rate (scaled by `SCALE`, capped at
     *        `MAX_PERFORMANCE_FEE`).
     * @param minAssets_ The seed deposit amount. Pulled from `msg.sender` before the proxy
     *        is created, then forwarded into the vault during `initialize()`.
     *
     * @return proxy The address of the newly deployed and initialized vault proxy.
     */
    function deployAndInitialize(
        address implementation,
        address proxyAdminOwner,
        address admin_,
        address timelock_,
        address asset_,
        string memory name_,
        string memory symbol_,
        IProvider[] memory providers_,
        address treasury_,
        uint96 managementFee_,
        uint96 performanceFee_,
        uint256 minAssets_
    ) external returns (address proxy) {
        if (implementation == address(0) || proxyAdminOwner == address(0)) {
            revert VaultDeployer__AddressZero();
        }

        IERC20 token = IERC20(asset_);

        // (a) Pull the seed deposit BEFORE the proxy exists. Nobody but msg.sender can
        // trigger this: it spends msg.sender's own allowance to this factory.
        token.safeTransferFrom(msg.sender, address(this), minAssets_);

        // (b) Empty constructor data ("") — critical, see contract-level comment for why
        // passing initData here would revert.
        TransparentUpgradeableProxy deployed = new TransparentUpgradeableProxy(
            implementation,
            proxyAdminOwner,
            ""
        );
        proxy = address(deployed);

        // (c) Approve the new proxy to pull the seed deposit during initialize()'s internal
        // _deposit() -> safeTransferFrom(caller = address(this), vault, minAssets_).
        token.forceApprove(proxy, minAssets_);

        // (d) Initialize as a normal external call, made only after the proxy's own
        // constructor has already returned and its runtime code is stored.
        IRebalancerInitializer(proxy).initialize(
            admin_,
            timelock_,
            asset_,
            name_,
            symbol_,
            providers_,
            treasury_,
            managementFee_,
            performanceFee_,
            minAssets_
        );

        emit VaultDeployed(proxy, implementation);
    }
}
