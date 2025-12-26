// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {MockProviderC} from "../../contracts/mocks/MockProvider.sol";
import {PausableActions} from "../../contracts/base/PausableActions.sol";
import {AccessManager} from "../../contracts/access/AccessManager.sol";
import {Vault} from "../../contracts/base/Vault.sol";
import {MockingUtilities} from "../utils/MockingUtilities.sol";

contract RebalancerCoreTests is MockingUtilities {
    event Deposit(
        address indexed sender,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event FeeCharged(address indexed treasury, uint256 fee);
    event TimelockUpdated(address indexed timelock);
    event ProvidersUpdated(IProvider[] providers);
    event ActiveProviderUpdated(IProvider activeProvider);
    event TreasuryUpdated(address indexed treasury);
    event WithdrawFeePercentUpdated(uint256 withdrawFeePercent);
    event MinAmountUpdated(uint256 minAmount);

    function setUp() public {
        initializeVault(vault, MIN_AMOUNT, initializer);
    }

    // =========================================
    // deposit & mint
    // =========================================

    function testDepositRevertsIfReceiverIsInvalid(uint256 assets) public {
        vm.expectRevert(Vault.Vault__AddressZero.selector);
        vm.prank(alice);
        vault.deposit(assets, address(0));
    }

    function testDepositRevertsIfAssetAmountIsInvalid() public {
        uint256 assets = 0;

        vm.expectRevert(Vault.Vault__InvalidInput.selector);
        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    function testDepositRevertsIfAssetAmountIsBelowMin() public {
        uint256 assets = MIN_AMOUNT - 1;

        vm.expectRevert(Vault.Vault__DepositLessThanMin.selector);
        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    function testDeposit(uint128 assets) public {
        vm.assume(assets >= MIN_AMOUNT);

        uint256 previousSharesBalance = vault.balanceOf(alice);
        uint256 mintedShares = executeDeposit(vault, assets, alice);

        uint256 assetBalance = vault.convertToAssets(mintedShares);
        uint256 totalAssets = vault.totalAssets();

        assertEq(vault.balanceOf(alice), previousSharesBalance + mintedShares);
        assertEq(assetBalance, assets);
        assertEq(totalAssets, assets + MIN_AMOUNT);
    }

    function testDepositEmitsEvent(uint128 assets) public {
        vm.assume(assets >= MIN_AMOUNT);
        asset.mint(alice, assets);

        uint256 shares = vault.previewDeposit(assets);

        vm.startPrank(alice);
        asset.approve(address(vault), assets);

        vm.expectEmit();
        emit Deposit(alice, alice, assets, shares);
        vault.deposit(assets, alice);
    }

    function testMint(uint128 shares) public {
        vm.assume(shares >= MIN_AMOUNT);

        uint256 pulledAssets = executeMint(vault, shares, alice);
        uint256 totalAssets = vault.totalAssets();

        assertEq(vault.balanceOf(alice), shares);
        assertEq(totalAssets, pulledAssets + MIN_AMOUNT);
    }

    function testMintEmitsEvent(uint128 shares) public {
        vm.assume(shares >= MIN_AMOUNT);

        uint256 assets = vault.previewMint(shares);

        asset.mint(alice, assets);

        vm.startPrank(alice);
        asset.approve(address(vault), assets);

        vm.expectEmit();
        emit Deposit(alice, alice, assets, shares);
        vault.mint(shares, alice);
    }

    // =========================================
    // withdraw & redeem
    // =========================================

    function testWithdrawRevertsIfReceiverIsInvalid(uint256 assets) public {
        vm.expectRevert(Vault.Vault__AddressZero.selector);
        vm.prank(alice);
        vault.withdraw(assets, address(0), alice);
    }

    function testWithdrawRevertsIfOwnerIsInvalid(uint256 assets) public {
        vm.expectRevert(Vault.Vault__AddressZero.selector);
        vm.prank(alice);
        vault.withdraw(assets, alice, address(0));
    }

    function testWithdrawRevertsIfAssetAmountIsInvalid() public {
        uint256 assets = 0;

        vm.expectRevert(Vault.Vault__InvalidInput.selector);
        vm.prank(alice);
        vault.withdraw(assets, alice, alice);
    }

    function testWithdrawMaxPossible(
        uint128 assets,
        uint128 moreThanAvailable
    ) public {
        vm.assume(assets >= MIN_AMOUNT && assets < moreThanAvailable);

        executeDeposit(vault, assets, alice);

        uint256 maxWithdraw = vault.maxWithdraw(alice);

        require(maxWithdraw < moreThanAvailable);

        executeWithdraw(vault, moreThanAvailable, alice);

        uint256 fee = (maxWithdraw * WITHDRAW_FEE_PERCENT) / PRECISION_FACTOR;
        uint256 assetBalance = maxWithdraw - fee;

        assertEq(asset.balanceOf(alice), assetBalance);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testRedeemMaxPossible(
        uint128 shares,
        uint128 moreThanAvailable
    ) public {
        vm.assume(shares >= MIN_AMOUNT && shares < moreThanAvailable);

        executeMint(vault, shares, alice);

        uint256 maxRedeem = vault.maxRedeem(alice);

        require(maxRedeem < moreThanAvailable);

        uint256 assets = vault.previewRedeem(maxRedeem);

        executeRedeem(vault, moreThanAvailable, alice);

        uint256 fee = (assets * WITHDRAW_FEE_PERCENT) / PRECISION_FACTOR;
        uint256 assetBalance = assets - fee;

        assertEq(asset.balanceOf(alice), assetBalance);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testWithdraw(uint128 assets) public {
        vm.assume(assets >= MIN_AMOUNT);

        IProvider[] memory providers = new IProvider[](3);
        providers[0] = mockProviderC;
        providers[1] = mockProviderB;
        providers[2] = mockProviderA; // remains the activeProvider

        vault.setProviders(providers);

        executeDeposit(vault, assets, alice);
        executeDeposit(vault, assets, bob);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = assets;
        amounts[1] = MIN_AMOUNT;

        IProvider[] memory sources = new IProvider[](2);
        sources[0] = mockProviderA;
        sources[1] = mockProviderA;

        IProvider[] memory destinations = new IProvider[](2);
        destinations[0] = mockProviderB;
        destinations[1] = mockProviderC;

        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            new uint256[](2)
        );

        assertEq(getBalanceAtProvider(vault, mockProviderC), MIN_AMOUNT);
        assertEq(getBalanceAtProvider(vault, mockProviderB), assets);
        assertEq(getBalanceAtProvider(vault, mockProviderA), assets);

        executeWithdraw(vault, assets, alice);

        assertEq(getBalanceAtProvider(vault, mockProviderC), 0);
        assertEq(getBalanceAtProvider(vault, mockProviderB), MIN_AMOUNT);
        assertEq(getBalanceAtProvider(vault, mockProviderA), assets);

        executeWithdraw(vault, assets, bob);

        assertEq(getBalanceAtProvider(vault, mockProviderC), 0);
        assertEq(getBalanceAtProvider(vault, mockProviderB), 0);
        assertEq(getBalanceAtProvider(vault, mockProviderA), MIN_AMOUNT);

        uint256 fee = (assets * WITHDRAW_FEE_PERCENT) / PRECISION_FACTOR;
        uint256 assetBalance = assets - fee;

        assertEq(asset.balanceOf(alice), assetBalance);
        assertEq(asset.balanceOf(bob), assetBalance);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    function testWithdrawEmitsEvent(uint128 assets) public {
        vm.assume(assets >= MIN_AMOUNT);

        executeDeposit(vault, assets, alice);

        uint256 shares = vault.previewWithdraw(assets);

        uint256 fee = (assets * WITHDRAW_FEE_PERCENT) / PRECISION_FACTOR;
        uint256 assetsToReceiver = assets - fee;

        vm.expectEmit();
        emit FeeCharged(treasury, fee);
        emit Withdraw(alice, alice, alice, assetsToReceiver, shares);
        vm.prank(alice);
        vault.withdraw(assets, alice, alice);
    }

    function testRedeem(uint128 shares) public {
        vm.assume(shares >= MIN_AMOUNT);

        IProvider[] memory providers = new IProvider[](3);
        providers[0] = mockProviderC;
        providers[1] = mockProviderB;
        providers[2] = mockProviderA; // remains the activeProvider

        vault.setProviders(providers);

        executeMint(vault, shares, alice);
        executeMint(vault, shares, bob);

        uint256 assets = vault.previewRedeem(shares);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = assets;
        amounts[1] = MIN_AMOUNT;

        IProvider[] memory sources = new IProvider[](2);
        sources[0] = mockProviderA;
        sources[1] = mockProviderA;

        IProvider[] memory destinations = new IProvider[](2);
        destinations[0] = mockProviderB;
        destinations[1] = mockProviderC;

        vaultManager.rebalanceVault(
            vault,
            amounts,
            sources,
            destinations,
            new uint256[](2)
        );

        assertEq(getBalanceAtProvider(vault, mockProviderC), MIN_AMOUNT);
        assertEq(getBalanceAtProvider(vault, mockProviderB), assets);
        assertEq(getBalanceAtProvider(vault, mockProviderA), assets);

        executeRedeem(vault, shares, alice);

        assertEq(getBalanceAtProvider(vault, mockProviderC), 0);
        assertEq(getBalanceAtProvider(vault, mockProviderB), MIN_AMOUNT);
        assertEq(getBalanceAtProvider(vault, mockProviderA), assets);

        executeRedeem(vault, shares, bob);

        assertEq(getBalanceAtProvider(vault, mockProviderC), 0);
        assertEq(getBalanceAtProvider(vault, mockProviderB), 0);
        assertEq(getBalanceAtProvider(vault, mockProviderA), MIN_AMOUNT);

        uint256 fee = (assets * WITHDRAW_FEE_PERCENT) / PRECISION_FACTOR;
        uint256 assetBalance = assets - fee;

        assertEq(asset.balanceOf(alice), assetBalance);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testRedeemEmitsEvent(uint128 shares) public {
        vm.assume(shares >= MIN_AMOUNT);

        executeMint(vault, shares, alice);

        uint256 assets = vault.previewRedeem(shares);

        uint256 fee = (assets * WITHDRAW_FEE_PERCENT) / PRECISION_FACTOR;
        uint256 assetsToReceiver = assets - fee;

        vm.expectEmit();
        emit FeeCharged(treasury, fee);
        emit Withdraw(alice, alice, alice, assetsToReceiver, shares);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    // =========================================
    // setTimelock
    // =========================================

    function testSetTimelockRevertsIfCallerIsNotTimelock(
        address _timelock
    ) public {
        vm.expectRevert(Vault.Vault__Unauthorized.selector);
        vm.prank(alice);
        vault.setTimelock(_timelock);
    }

    function testSetTimelockRevertsIfTimelockIsInvalid() public {
        vm.expectRevert(Vault.Vault__AddressZero.selector);
        vault.setTimelock(address(0));
    }

    function testSetTimelock(address _timelock) public {
        vm.assume(_timelock != address(0));

        vault.setTimelock(_timelock);

        assertEq(vault.timelock(), _timelock);
    }

    function testSetTimelockEmitsEvent(address _timelock) public {
        vm.assume(_timelock != address(0));

        vm.expectEmit();
        emit TimelockUpdated(_timelock);
        vault.setTimelock(_timelock);
    }

    // =========================================
    // setProviders
    // =========================================

    function testSetProvidersRevertsIfCallerIsNotTimelock() public {
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = mockProviderC;

        vm.expectRevert(Vault.Vault__Unauthorized.selector);
        vm.prank(alice);
        vault.setProviders(providers);
    }

    function testSetProvidersRevertsIfProviderIsInvalid() public {
        IProvider[] memory providers = new IProvider[](2);
        providers[0] = mockProviderC;
        providers[1] = IProvider(address(0));

        vm.expectRevert(Vault.Vault__AddressZero.selector);
        vault.setProviders(providers);
    }

    function testSetProviders() public {
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = mockProviderC;

        vault.setProviders(providers);

        assertEq(address(vault.getProviders()[0]), address(mockProviderC));
    }

    function testSetProvidersEmitsEvent() public {
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = mockProviderC;

        vm.expectEmit();
        emit ProvidersUpdated(providers);
        vault.setProviders(providers);
    }

    // =========================================
    // setActiveProvider
    // =========================================

    function testSetActiveProviderRevertsIfCallerIsNotAdmin() public {
        vm.expectRevert(AccessManager.AccessManager__CallerIsNotAdmin.selector);
        vm.prank(alice);
        vault.setActiveProvider(mockProviderB);
    }

    function testSetActiveProviderRevertsIfProviderIsInvalid() public {
        vm.expectRevert(Vault.Vault__InvalidInput.selector);
        vault.setActiveProvider(mockProviderC);
    }

    function testSetActiveProvider() public {
        vault.setActiveProvider(mockProviderB);

        assertEq(address(vault.activeProvider()), address(mockProviderB));
    }

    function testSetActiveProviderEmitsEvent() public {
        vm.expectEmit();
        emit ActiveProviderUpdated(mockProviderB);
        vault.setActiveProvider(mockProviderB);
    }

    // =========================================
    // setTreasury
    // =========================================

    function testSetTreasuryRevertsIfCallerIsNotAdmin(
        address _treasury
    ) public {
        vm.expectRevert(AccessManager.AccessManager__CallerIsNotAdmin.selector);
        vm.prank(alice);
        vault.setTreasury(_treasury);
    }

    function testSetTreasuryRevertsWhenInvalidTreasury() public {
        vm.expectRevert(Vault.Vault__AddressZero.selector);
        vault.setTreasury(address(0));
    }

    function testSetTreasury(address _treasury) public {
        vm.assume(_treasury != address(0));
        vault.setTreasury(_treasury);

        assertEq(vault.treasury(), _treasury);
    }

    function testSetTreasuryEmitsEvent(address _treasury) public {
        vm.assume(_treasury != address(0));
        vm.expectEmit();
        emit TreasuryUpdated(_treasury);
        vault.setTreasury(_treasury);
    }

    // =========================================
    // setWithdrawFeePercent
    // =========================================

    function testSetWithdrawFeePercentRevertsIfCallerIsNotAdmin(
        uint256 withdrawFeePercent
    ) public {
        vm.expectRevert(AccessManager.AccessManager__CallerIsNotAdmin.selector);
        vm.prank(alice);
        vault.setWithdrawFeePercent(withdrawFeePercent);
    }

    function testSetWithdrawFeePercentRevertsIfFeeIsInvalid() public {
        uint256 withdrawFeePercent = MAX_WITHDRAW_FEE_PERCENT + 1;
        vm.expectRevert(Vault.Vault__InvalidInput.selector);
        vault.setWithdrawFeePercent(withdrawFeePercent);
    }

    function testSetWithdrawFeePercent(uint256 withdrawFeePercent) public {
        vm.assume(withdrawFeePercent <= MAX_WITHDRAW_FEE_PERCENT);
        vault.setWithdrawFeePercent(withdrawFeePercent);

        assertEq(vault.withdrawFeePercent(), withdrawFeePercent);
    }

    function testSetWithdrawFeePercentEmitsEvent(
        uint256 withdrawFeePercent
    ) public {
        vm.assume(withdrawFeePercent <= MAX_WITHDRAW_FEE_PERCENT);
        vm.expectEmit();
        emit WithdrawFeePercentUpdated(withdrawFeePercent);
        vault.setWithdrawFeePercent(withdrawFeePercent);
    }

    // =========================================
    // setMinAmount
    // =========================================

    function testSetMinAmountRevertsIfCallerIsNotAdmin(
        uint256 minAmount
    ) public {
        vm.expectRevert(AccessManager.AccessManager__CallerIsNotAdmin.selector);
        vm.prank(alice);
        vault.setMinAmount(minAmount);
    }

    function testSetMinAmount(uint256 minAmount) public {
        vault.setMinAmount(minAmount);

        assertEq(vault.minAmount(), minAmount);
    }

    function testSetMinAmountEmitsEvent(uint256 minAmount) public {
        vm.expectEmit();
        emit MinAmountUpdated(minAmount);
        vault.setMinAmount(minAmount);
    }

    // =========================================
    // maxDeposit & maxMint
    // =========================================

    function testMaxDepositAndMaxMint() public {
        vault.pause(PausableActions.Actions.Deposit);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);

        vault.unpause(PausableActions.Actions.Deposit);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    // =========================================
    // maxWithdraw & maxRedeem
    // =========================================

    function testMaxWithdrawAndMaxRedeem(uint128 assets) public {
        vm.assume(assets >= MIN_AMOUNT);

        executeDeposit(vault, assets, alice);

        vault.pause(PausableActions.Actions.Withdraw);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);

        vault.unpause(PausableActions.Actions.Withdraw);
        assertEq(vault.maxWithdraw(alice), vault.getBalanceOfAsset(alice));
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice));
    }
}
