// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title VaultFactory
 * @notice Deploys a vault proxy and initializes it inside a single transaction.
 * @dev A proxy created in one transaction and initialized in another is exposed between
 *      the two: on chains whose ordering is not first-come-first-served (Ethereum mainnet
 *      orders by builder choice) an observer can call `initialize` first and take admin of
 *      a vault that carries the protocol's providers. Doing both in one transaction leaves
 *      no such window, because the proxy address never exists in an uninitialized state.
 *
 *      Initialization cannot be moved into the proxy constructor instead: `initialize`
 *      resolves provider sources and then delegatecalls the entry provider, which calls
 *      back into `vault.asset()`, and the proxy has no code while its own constructor runs.
 *
 *      The contract holds no state and no privileges; it only relays a seed deposit that
 *      `initialize` pulls from its own caller.
 */
contract VaultFactory {
    using SafeERC20 for IERC20;

    error NotSeedOwner();

    event VaultDeployed(
        address indexed vault,
        address indexed implementation,
        address indexed admin
    );

    /**
     * @notice Deploys the proxy, funds the seed deposit and initializes the vault atomically.
     * @param implementation_ Vault implementation the proxy delegates to.
     * @param admin_ Owner of the ProxyAdmin the proxy constructor creates (protocol treasury).
     * @param seedOwner_ Account the seed deposit is pulled from; must be the caller.
     * @param asset_ Seed asset, the same asset the vault is initialized with.
     * @param seedAmount_ Seed amount, equal to the `minAssets_` passed in `initData_`.
     * @param initData_ `initialize(...)` calldata for the implementation.
     * @return vault Address of the deployed and initialized proxy.
     */
    function deployAndInitialize(
        address implementation_,
        address admin_,
        address seedOwner_,
        IERC20 asset_,
        uint256 seedAmount_,
        bytes calldata initData_
    ) external returns (address vault) {
        if (msg.sender != seedOwner_) {
            revert NotSeedOwner();
        }

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            implementation_,
            admin_,
            ""
        );
        vault = address(proxy);

        // initialize() transfers minAssets from its own msg.sender, which is this contract.
        asset_.safeTransferFrom(seedOwner_, address(this), seedAmount_);
        asset_.forceApprove(vault, seedAmount_);

        (bool success, ) = vault.call(initData_);
        if (!success) {
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        // initialize consumed minAssets; drop the allowance that is left over
        // when seedAmount_ was set above it
        asset_.forceApprove(vault, 0);

        // a seedAmount_ larger than the configured minAssets_ would otherwise be stranded here
        uint256 leftover = asset_.balanceOf(address(this));
        if (leftover != 0) {
            asset_.safeTransfer(seedOwner_, leftover);
        }

        emit VaultDeployed(vault, implementation_, admin_);
    }
}
