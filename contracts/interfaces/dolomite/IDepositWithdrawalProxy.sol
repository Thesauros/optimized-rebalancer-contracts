// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.23;

/**
 * @title IDepositWithdrawalProxy
 * @dev Modified version of the original Dolomite interface.
 */
interface IDepositWithdrawalProxy {
    /// Checks that either BOTH, FROM, or TO accounts all have non-negative balances
    enum BalanceCheckFlag {
        Both,
        From,
        To,
        None
    }

    /**
     * @param _toAccountIndex   The index into which `msg.sender` will be depositing
     * @param _marketId         The ID of the market being deposited
     * @param _amountWei        The amount, in Wei, to deposit. Use `uint(-1)` to deposit `msg.sender`'s entire balance
     */
    function depositWei(
        uint256 _toAccountIndex,
        uint256 _marketId,
        uint256 _amountWei
    ) external;

    /**
     * Same as `depositWei` but converts the `msg.sender`'s sent ETH into WETH before depositing into `DolomiteMargin`.
     *
     * @param _toAccountIndex The index into which `msg.sender` will be depositing
     */
    function depositETH(uint256 _toAccountIndex) external payable;

    /**
     * @dev Same as `depositWei` but defaults to account index 0 to save additional call data
     *
     * @param _marketId     The ID of the market being deposited
     * @param _amountWei    The amount, in Wei, to deposit. Use `uint(-1)` to deposit `msg.sender`'s entire balance
     */
    function depositWeiIntoDefaultAccount(
        uint256 _marketId,
        uint256 _amountWei
    ) external;

    /**
     * Same as `depositWeiIntoDefaultAccount` but converts the `msg.sender`'s sent ETH into WETH before depositing into
     * `DolomiteMargin`.
     */
    function depositETHIntoDefaultAccount() external payable;

    /**
     * @param _fromAccountIndex The index from which `msg.sender` will be withdrawing
     * @param _marketId         The ID of the market being withdrawn
     * @param _amountWei        The amount, in Wei, to withdraw. Use `uint(-1)` to withdraw `msg.sender`'s entire
     *                          balance
     * @param _balanceCheckFlag Use `BalanceCheckFlag.Both` or `BalanceCheckFlag.From` to check that `_fromAccountIndex`
     *                          balance is non-negative after the withdrawal settles.
     */
    function withdrawWei(
        uint256 _fromAccountIndex,
        uint256 _marketId,
        uint256 _amountWei,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    /**
     * Same as `withdrawWei` but for withdrawing ETH. The user will receive unwrapped ETH from DolomiteMargin.
     *
     * @param _fromAccountIndex     The index from which `msg.sender` will be withdrawing
     * @param _amountWei        The amount, in Wei, to withdraw. Use `uint(-1)` to withdraw `msg.sender`'s entire
     *                          balance.
     * @param _balanceCheckFlag Use `BalanceCheckFlag.Both` or `BalanceCheckFlag.From` to check that `_fromAccountIndex`
     *                          balance is non-negative after the withdrawal settles.
     */
    function withdrawETH(
        uint256 _fromAccountIndex,
        uint256 _amountWei,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    /**
     * @dev Same as `withdrawWei` but defaults to account index 0 to save additional call data
     *
     * @param _marketId         The ID of the market being withdrawn
     * @param _amountWei        The amount, in Wei, to withdraw. Use `uint(-1)` to withdraw `msg.sender`'s entire
     *                          balance
     * @param _balanceCheckFlag Use `BalanceCheckFlag.Both` or `BalanceCheckFlag.From` to check that `_fromAccountIndex`
     *                          balance is non-negative after the withdrawal settles.
     */
    function withdrawWeiFromDefaultAccount(
        uint256 _marketId,
        uint256 _amountWei,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    /**
     * Same as `withdrawWeiFromDefaultAccount` but for withdrawing ETH. The user will receive unwrapped ETH from
     * DolomiteMargin.
     *
     * @param _amountWei        The amount, in Wei, to withdraw. Use `uint(-1)` to withdraw `msg.sender`'s entire
     *                          balance
     * @param _balanceCheckFlag Use `BalanceCheckFlag.Both` or `BalanceCheckFlag.From` to check that `_fromAccountIndex`
     *                          balance is non-negative after the withdrawal settles.
     */
    function withdrawETHFromDefaultAccount(
        uint256 _amountWei,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    /**
     * @param _toAccountIndex   The index into which `msg.sender` will be depositing
     * @param _marketId         The ID of the market being deposited
     * @param _amountPar        The amount, in Par, to deposit.
     */
    function depositPar(
        uint256 _toAccountIndex,
        uint256 _marketId,
        uint256 _amountPar
    ) external;

    /**
     * @dev Same as `depositPar` but defaults to account index 0 to save additional call data
     *
     * @param _marketId     The ID of the market being deposited
     * @param _amountPar    The amount, in Par, to deposit.
     */
    function depositParIntoDefaultAccount(
        uint256 _marketId,
        uint256 _amountPar
    ) external;

    /**
     * @param _fromAccountIndex     The index from which `msg.sender` will be withdrawing
     * @param _marketId         The ID of the market being withdrawn
     * @param _amountPar        The amount, in Par, to withdraw. Use `uint(-1)` to withdraw `msg.sender`'s entire
     *                          balance
     * @param _balanceCheckFlag Use `BalanceCheckFlag.Both` or `BalanceCheckFlag.From` to check that `_fromAccountIndex`
     *                          balance is non-negative after the withdrawal settles.
     */
    function withdrawPar(
        uint256 _fromAccountIndex,
        uint256 _marketId,
        uint256 _amountPar,
        BalanceCheckFlag _balanceCheckFlag
    ) external;

    /**
     * @dev Same as `withdrawPar` but defaults to account index 0 to save additional call data
     *
     * @param _marketId         The ID of the market being withdrawn
     * @param _amountPar        The amount, in Par, to withdraw. Use `uint(-1)` to withdraw `msg.sender`'s entire balance
     * @param _balanceCheckFlag Use `BalanceCheckFlag.Both` or `BalanceCheckFlag.From` to check that `_fromAccountIndex`
     *                          balance is non-negative after the withdrawal settles.
     */
    function withdrawParFromDefaultAccount(
        uint256 _marketId,
        uint256 _amountPar,
        BalanceCheckFlag _balanceCheckFlag
    ) external;
}
