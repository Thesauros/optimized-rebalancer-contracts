// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockYieldSource
 * @notice Test double standing in for an external lending market (Aave's Pool, Compound's
 *         Comet, a MetaMorpho vault, ...). Deliberately a PLAIN contract that is never
 *         delegatecalled by anything — `MockProvider` calls into it via ordinary external
 *         `CALL`s, exactly mirroring how the real provider adapters call out to their
 *         underlying protocol. All of the suite's mutable/adversarial test state lives
 *         here (not on `MockProvider`) for that reason — see `MockProvider`'s NatSpec.
 */
contract MockYieldSource {
    using SafeERC20 for IERC20;

    error MockYieldSource__ForcedRevert();

    IERC20 public immutable asset;

    /// @dev vault => assets this source reports as deposited on that vault's behalf.
    mapping(address vault => uint256) public balances;

    bool public shouldRevertOnDeposit;
    bool public shouldRevertOnWithdraw;
    bool public shouldRevertOnGetBalance;

    /// @dev If true, `debitAndSend` only ever moves half of the requested amount,
    /// simulating a provider that cannot fully honor a withdrawal request.
    bool public partialWithdraw;

    mapping(address vault => uint256) private _balanceOverride;
    mapping(address vault => bool) private _hasBalanceOverride;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function setShouldRevertOnDeposit(bool value) external {
        shouldRevertOnDeposit = value;
    }

    function setShouldRevertOnWithdraw(bool value) external {
        shouldRevertOnWithdraw = value;
    }

    function setShouldRevertOnGetBalance(bool value) external {
        shouldRevertOnGetBalance = value;
    }

    function setPartialWithdraw(bool value) external {
        partialWithdraw = value;
    }

    /// @notice Forces `balanceOf(vault)` to report `amount` regardless of the internal
    /// ledger, until `clearBalanceOverride` is called. Does not move any tokens — a
    /// surgical knob for exercising `getDepositBalance`/aggregation logic directly.
    function setBalanceOverride(address vault, uint256 amount) external {
        _balanceOverride[vault] = amount;
        _hasBalanceOverride[vault] = true;
    }

    function clearBalanceOverride(address vault) external {
        _hasBalanceOverride[vault] = false;
    }

    /// @notice Pulls `amount` of `asset` from the caller and credits `vault`'s ledger
    /// balance. Mirrors a real provider's `deposit()` pulling from the vault (which is
    /// `msg.sender` here, since `MockProvider.deposit` runs via delegatecall from the
    /// vault and therefore calls this as the vault itself).
    function creditDeposit(address vault, uint256 amount) external {
        if (shouldRevertOnDeposit) revert MockYieldSource__ForcedRevert();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        balances[vault] += amount;
    }

    /// @notice Debits `vault`'s ledger balance and sends the corresponding `asset` to `to`.
    /// @dev If `partialWithdraw` is set, only half of `amount` (rounded down) is actually
    /// moved/debited, simulating a provider that cannot fully honor the request; the call
    /// still succeeds (does not revert) so callers observe a genuine partial fill.
    function debitAndSend(
        address vault,
        uint256 amount,
        address to
    ) external returns (uint256 sent) {
        if (shouldRevertOnWithdraw) revert MockYieldSource__ForcedRevert();
        sent = partialWithdraw ? amount / 2 : amount;
        balances[vault] -= sent;
        if (sent > 0) {
            asset.safeTransfer(to, sent);
        }
    }

    function balanceOf(address vault) external view returns (uint256) {
        if (shouldRevertOnGetBalance) revert MockYieldSource__ForcedRevert();
        if (_hasBalanceOverride[vault]) return _balanceOverride[vault];
        return balances[vault];
    }

    /// @notice Test helper: simulates yield accruing at the source for `vault`. Pulls the
    /// backing tokens from the caller (mirroring `creditDeposit`) so this source never
    /// reports a higher balance than it can actually pay out on a subsequent withdrawal.
    function simulateYield(address vault, uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        balances[vault] += amount;
    }

    /// @notice Test helper: simulates a loss (e.g. realized bad debt) at the source for
    /// `vault`. Does not move any tokens out — a real loss means the backing value is
    /// simply gone, not sent anywhere.
    function simulateLoss(address vault, uint256 amount) external {
        uint256 bal = balances[vault];
        balances[vault] = amount >= bal ? 0 : bal - amount;
    }
}
