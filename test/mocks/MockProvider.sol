// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {MockYieldSource} from "./MockYieldSource.sol";

/**
 * @title MockProvider
 * @notice Test double for a lending-market adapter (à la `AaveV3Provider`/
 *         `MorphoProvider`/`CompoundV3Provider`).
 *
 * @dev `deposit`/`withdraw` are DELEGATECALLED by the vault (per `IProvider`'s contract:
 *      "This function should be delegate called in the context of a vault."), so while
 *      they execute, `address(this) == vault`. This contract therefore holds NO mutable
 *      storage of its own: any `SSTORE` here would land in the VAULT's storage layout, not
 *      this contract's, silently corrupting vault state. All configuration below is
 *      `immutable` (baked into runtime bytecode, unaffected by delegatecall) and
 *      `getIdentifier()` returns a `pure` literal — exactly like the real
 *      `AaveV3Provider`/`MorphoProvider`/`CompoundV3Provider` adapters, which hold only
 *      `immutable` addresses. All actual mutable/adversarial test state (revert toggles,
 *      balance ledger, overrides) lives on the shared `MockYieldSource` instead, which is
 *      a plain contract this provider only ever reaches via ordinary external `CALL`s.
 */
contract MockProvider is IProvider {
    MockYieldSource private immutable _source;

    constructor(MockYieldSource source_) {
        _source = source_;
    }

    /**
     * @inheritdoc IProvider
     */
    function deposit(
        uint256 amount,
        IRebalancer vault
    ) external override returns (bool success) {
        _source.creditDeposit(address(vault), amount);
        success = true;
    }

    /**
     * @inheritdoc IProvider
     */
    function withdraw(
        uint256 amount,
        IRebalancer vault
    ) external override returns (bool success) {
        _source.debitAndSend(address(vault), amount, address(vault));
        success = true;
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositBalance(
        address user,
        IRebalancer
    ) external view override returns (uint256 balance) {
        balance = _source.balanceOf(user);
    }

    /**
     * @inheritdoc IProvider
     */
    function getDepositRate(
        IRebalancer
    ) external pure override returns (uint256 rate) {
        return 0;
    }

    /**
     * @inheritdoc IProvider
     */
    function getSource(
        address,
        address,
        address
    ) external view override returns (address source) {
        source = address(_source);
    }

    /**
     * @inheritdoc IProvider
     */
    function getIdentifier() public pure override returns (string memory) {
        return "Mock_Provider";
    }

    /// @notice Test helper exposing which `MockYieldSource` this provider relays to.
    function mockSource() external view returns (MockYieldSource) {
        return _source;
    }
}
