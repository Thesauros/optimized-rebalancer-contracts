// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProvider} from "../interfaces/IProvider.sol";
import {IRebalancer} from "../interfaces/IRebalancer.sol";
import {IMeshNode} from "./interfaces/IMeshNode.sol";

/// @notice Principal-only Mesh integration for the existing Meridian vault.
/// @dev All configuration is immutable: deposit/withdraw run in vault storage.
contract MeshProvider is IProvider {
    using SafeERC20 for IERC20;

    error InvalidNode();
    error InvalidContext();
    error UnexpectedTokenAmount();

    IMeshNode public immutable node;
    address private immutable _self;
    address private immutable _asset;

    constructor(IMeshNode node_) {
        if (address(node_).code.length == 0) revert InvalidNode();
        address token = node_.asset();
        if (token.code.length == 0) revert InvalidNode();
        node = node_;
        _asset = token;
        _self = address(this);
    }

    modifier onlyVaultContext(IRebalancer vault) {
        if (address(this) == _self || address(this) != address(vault)) revert InvalidContext();
        if (vault.asset() != _asset) revert InvalidContext();
        _;
    }

    function deposit(uint256 amount, IRebalancer vault)
        external
        onlyVaultContext(vault)
        returns (bool)
    {
        uint256 beforeBalance = IERC20(_asset).balanceOf(address(node));
        IERC20(_asset).safeTransfer(address(node), amount);
        uint256 afterBalance = IERC20(_asset).balanceOf(address(node));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnexpectedTokenAmount();
        node.depositFromVault(amount);
        return true;
    }

    /// @dev Exact-or-revert: Rebalancer.rebalance ignores bool/actual withdrawal
    /// amounts. Its user-withdraw path can catch this revert and try the next provider.
    function withdraw(uint256 amount, IRebalancer vault)
        external
        onlyVaultContext(vault)
        returns (bool)
    {
        node.withdrawToVault(amount);
        return true;
    }

    function getDepositBalance(address user, IRebalancer) external view returns (uint256) {
        return node.balanceOf(user);
    }

    /// @dev Remote yield accounting is a later milestone; do not advertise an APR.
    function getDepositRate(IRebalancer) external pure returns (uint256) {
        return 0;
    }

    /// @dev The vault approves this address, but MeshNode never pulls vault funds.
    function getSource(address, address, address) external view returns (address) {
        return address(node);
    }

    function getIdentifier() external pure returns (string memory) {
        return "CrossChain_Mesh_Provider";
    }
}
