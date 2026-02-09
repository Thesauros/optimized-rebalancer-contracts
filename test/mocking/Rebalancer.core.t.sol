// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IERC4626} from "../../contracts/interfaces/IERC4626.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {MockProvider} from "../../contracts/mocks/MockProvider.sol";
import {AccessManager} from "../../contracts/access/AccessManager.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";
import "../../contracts/libraries/Constants.sol";

contract RebalancerCoreTests is MockingBase {
    
    // =========================================
    // deposit & mint
    // =========================================

    function testDepositRevertsIfReceiverIsAddressZero(uint256 assets) public {
        vm.prank(alice);
        vm.expectRevert(IRebalancer.AddressZero.selector);
        vault.deposit(assets, address(0));
    }

    function testDepositRevertsIfAssetsIsZero() public {
        uint256 assets = 0;

        vm.prank(alice);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.deposit(assets, alice);
    }

    function testDepositRevertsIfAssetsBelowMin() public {
        uint256 assets = minAssets - 1;

        vm.prank(alice);
        vm.expectRevert(IRebalancer.AssetsBelowMin.selector);
        vault.deposit(assets, alice);
    }

    function testDeposit(uint256 assets) public {
        assets = bound(assets, minAssets, maxTestAssets);

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 previewed = vault.previewDeposit(assets);

        uint256 shares = _executeDeposit(vault, assets, alice);

        assertEq(shares, previewed);

        assertEq(vault.balanceOf(alice), sharesBefore + shares);
        assertEq(vault.convertToAssets(shares), assets);
        assertEq(vault.totalAssets(), initialTotalAssets + assets);
        assertEq(vault.totalSupply(), initialTotalSupply + shares);
    }

    function testDepositEmitsEvents(uint256 assets) public {
        assets = bound(assets, minAssets, maxTestAssets);

        deal(address(asset), alice, assets);

        uint256 previewed = vault.previewDeposit(assets);

        vm.startPrank(alice);
        asset.approve(address(vault), assets);

        vm.expectEmit(address(vault));
        emit IRebalancer.FeesApplied(
            initialTotalAssets,
            initialTotalAssets,
            0,
            0
        );
        vm.expectEmit(address(vault));
        emit IERC4626.Deposit(alice, alice, assets, previewed);
        vault.deposit(assets, alice);

        vm.stopPrank();
    }

    function testMint(uint256 shares) public {
        uint256 minShares = vault.convertToShares(minAssets); // explicit even if price is 1:1
        shares = bound(shares, minShares, maxTestShares);

        uint256 sharesBefore = vault.balanceOf(alice);

        uint256 assets = _executeMint(vault, shares, alice);

        assertEq(vault.balanceOf(alice), sharesBefore + shares);
        assertEq(vault.convertToAssets(shares), assets);
        assertEq(vault.totalAssets(), initialTotalAssets + assets);
        assertEq(vault.totalSupply(), initialTotalSupply + shares);
    }

    function testMintEmitsEvents(uint256 shares) public {
        uint256 minShares = vault.convertToShares(minAssets);
        shares = bound(shares, minShares, maxTestShares);

        uint256 previewed = vault.previewMint(shares);
        deal(address(asset), alice, previewed);

        vm.startPrank(alice);
        asset.approve(address(vault), previewed);

        vm.expectEmit(address(vault));
        emit IRebalancer.FeesApplied(
            initialTotalAssets,
            initialTotalAssets,
            0,
            0
        );
        vm.expectEmit(address(vault));
        emit IERC4626.Deposit(alice, alice, previewed, shares);
        vault.mint(shares, alice);

        vm.stopPrank();
    }

    // =========================================
    // withdraw & redeem
    // =========================================

    function testWithdrawRevertsIfReceiverIsAddressZero(uint256 assets) public {
        vm.prank(alice);
        vm.expectRevert(IRebalancer.AddressZero.selector);
        vault.withdraw(assets, address(0), alice);
    }

    function testWithdrawRevertsIfOwnerIsAddressZero(uint256 assets) public {
        vm.prank(alice);
        vm.expectRevert(IRebalancer.AddressZero.selector);
        vault.withdraw(assets, alice, address(0));
    }

    function testWithdrawRevertsIfAssetsIsZero() public {
        uint256 assets = 0;

        vm.prank(alice);
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.withdraw(assets, alice, alice);
    }

    function testWithdraw(uint256 assets) public {
        assets = bound(assets, minAssets, maxTestAssets);

        IProvider[] memory providers = new IProvider[](3);
        providers[0] = mockProviderC;
        providers[1] = mockProviderB;
        providers[2] = mockProviderA; // remains the entryProvider

        vault.setProviders(providers);

        _executeDeposit(vault, assets, alice);
        _executeDeposit(vault, assets, bob);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = assets;
        amounts[1] = initialTotalAssets;

        IProvider[] memory sources = new IProvider[](2);
        sources[0] = mockProviderA;
        sources[1] = mockProviderA;

        IProvider[] memory destinations = new IProvider[](2);
        destinations[0] = mockProviderB;
        destinations[1] = mockProviderC;

        vault.rebalance(amounts, sources, destinations);

        assertEq(
            _getAssetsAtProvider(vault, mockProviderC),
            initialTotalAssets
        );
        assertEq(_getAssetsAtProvider(vault, mockProviderB), assets);
        assertEq(_getAssetsAtProvider(vault, mockProviderA), assets);

        uint256 expectedTotalAssets = vault.totalAssets();
        uint256 expectedTotalSupply = vault.totalSupply();

        // alice withdraws

        uint256 previewedAlice = vault.previewWithdraw(assets);
        uint256 sharesAlice = _executeWithdraw(vault, assets, alice);

        assertEq(sharesAlice, previewedAlice);

        expectedTotalAssets -= assets;
        expectedTotalSupply -= sharesAlice;

        assertEq(vault.totalAssets(), expectedTotalAssets);
        assertEq(vault.totalSupply(), expectedTotalSupply);
        assertEq(vault.getLastTotalAssets(), vault.totalAssets());

        assertEq(_getAssetsAtProvider(vault, mockProviderC), 0);
        assertEq(
            _getAssetsAtProvider(vault, mockProviderB),
            initialTotalAssets
        );
        assertEq(_getAssetsAtProvider(vault, mockProviderA), assets);

        // bob withdraws

        uint256 previewedBob = vault.previewWithdraw(assets);
        uint256 sharesBob = _executeWithdraw(vault, assets, bob);

        assertEq(sharesBob, previewedBob);

        expectedTotalAssets -= assets;
        expectedTotalSupply -= sharesBob;

        assertEq(vault.totalAssets(), expectedTotalAssets);
        assertEq(vault.totalSupply(), expectedTotalSupply);
        assertEq(vault.getLastTotalAssets(), vault.totalAssets());

        assertEq(_getAssetsAtProvider(vault, mockProviderC), 0);
        assertEq(_getAssetsAtProvider(vault, mockProviderB), 0);
        assertEq(
            _getAssetsAtProvider(vault, mockProviderA),
            initialTotalAssets
        );

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    function testWithdrawEmitsEvents(uint256 assets) public {
        assets = bound(assets, minAssets, maxTestAssets);

        _executeDeposit(vault, assets, alice);

        uint256 previewed = vault.previewWithdraw(assets);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit IRebalancer.FeesApplied(
            initialTotalAssets + assets,
            initialTotalAssets + assets,
            0,
            0
        );
        vm.expectEmit(address(vault));
        emit IERC4626.Withdraw(alice, alice, alice, assets, previewed);
        vault.withdraw(assets, alice, alice);
    }

    function testRedeem(uint256 shares) public {
        uint256 minShares = vault.convertToShares(minAssets); // explicit even if price is 1:1
        shares = bound(shares, minShares, maxTestShares);

        IProvider[] memory providers = new IProvider[](3);
        providers[0] = mockProviderC;
        providers[1] = mockProviderB;
        providers[2] = mockProviderA; // remains the entryProvider

        vault.setProviders(providers);

        _executeMint(vault, shares, alice);
        _executeMint(vault, shares, bob);

        uint256 assets = vault.convertToAssets(shares);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = assets;
        amounts[1] = initialTotalAssets;

        IProvider[] memory sources = new IProvider[](2);
        sources[0] = mockProviderA;
        sources[1] = mockProviderA;

        IProvider[] memory destinations = new IProvider[](2);
        destinations[0] = mockProviderB;
        destinations[1] = mockProviderC;

        vault.rebalance(amounts, sources, destinations);

        assertEq(
            _getAssetsAtProvider(vault, mockProviderC),
            initialTotalAssets
        );
        assertEq(_getAssetsAtProvider(vault, mockProviderB), assets);
        assertEq(_getAssetsAtProvider(vault, mockProviderA), assets);

        uint256 expectedTotalAssets = vault.totalAssets();
        uint256 expectedTotalSupply = vault.totalSupply();

        // alice redeems

        uint256 previewedAlice = vault.previewRedeem(shares);
        uint256 assetsAlice = _executeRedeem(vault, shares, alice);

        assertEq(assetsAlice, previewedAlice);

        expectedTotalAssets -= assetsAlice;
        expectedTotalSupply -= shares;

        assertEq(vault.totalAssets(), expectedTotalAssets);
        assertEq(vault.totalSupply(), expectedTotalSupply);
        assertEq(vault.getLastTotalAssets(), vault.totalAssets());

        assertEq(_getAssetsAtProvider(vault, mockProviderC), 0);
        assertEq(
            _getAssetsAtProvider(vault, mockProviderB),
            initialTotalAssets
        );
        assertEq(_getAssetsAtProvider(vault, mockProviderA), assets);

        // bob redeems

        uint256 previewedBob = vault.previewRedeem(shares);
        uint256 assetsBob = _executeRedeem(vault, shares, bob);

        assertEq(assetsBob, previewedBob);

        expectedTotalAssets -= assetsBob;
        expectedTotalSupply -= shares;

        assertEq(vault.totalAssets(), expectedTotalAssets);
        assertEq(vault.totalSupply(), expectedTotalSupply);
        assertEq(vault.getLastTotalAssets(), vault.totalAssets());

        assertEq(_getAssetsAtProvider(vault, mockProviderC), 0);
        assertEq(_getAssetsAtProvider(vault, mockProviderB), 0);
        assertEq(
            _getAssetsAtProvider(vault, mockProviderA),
            initialTotalAssets
        );

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 0);
    }

    function testRedeemEmitsEvents(uint256 shares) public {
        uint256 minShares = vault.convertToShares(minAssets); // explicit even if price is 1:1
        shares = bound(shares, minShares, maxTestShares);

        uint256 assets = _executeMint(vault, shares, alice);

        uint256 previewed = vault.previewRedeem(shares);

        vm.prank(alice);
        vm.expectEmit(address(vault));
        emit IRebalancer.FeesApplied(
            initialTotalAssets + assets,
            initialTotalAssets + assets,
            0,
            0
        );
        vm.expectEmit(address(vault));
        emit IERC4626.Withdraw(alice, alice, alice, previewed, shares);
        vault.redeem(shares, alice, alice);
    }

    // =========================================
    // setProviders
    // =========================================

    function testSetProvidersRevertsIfCallerIsNotTimelock() public {
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = mockProviderC;

        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setProviders(providers);
    }

    function testSetProvidersRevertsIfProviderIsAddressZero() public {
        IProvider[] memory providers = new IProvider[](2);
        providers[0] = mockProviderC;
        providers[1] = IProvider(address(0));

        vm.expectRevert(IRebalancer.AddressZero.selector);
        vault.setProviders(providers);
    }

    function testSetProviders() public {
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = mockProviderC;

        vault.setProviders(providers);

        assertEq(address(vault.getProviders()[0]), address(mockProviderC));
        assertEq(
            asset.allowance(address(vault), address(mockProtocolC)),
            type(uint256).max
        );
    }

    function testSetProvidersEmitsEvent() public {
        IProvider[] memory providers = new IProvider[](1);
        providers[0] = mockProviderC;

        vm.expectEmit(address(vault));
        emit IRebalancer.ProvidersUpdated(providers);
        vault.setProviders(providers);
    }

    // =========================================
    // setEntryProvider
    // =========================================

    function testSetEntryProviderRevertsIfCallerIsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setEntryProvider(mockProviderB);
    }

    function testSetEntryProviderRevertsIfProviderIsInvalid() public {
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setEntryProvider(mockProviderC);
    }

    function testSetEntryProvider() public {
        vault.setEntryProvider(mockProviderB);

        assertEq(address(vault.getEntryProvider()), address(mockProviderB));
    }

    function testSetEntryProviderEmitsEvent() public {
        vm.expectEmit(address(vault));
        emit IRebalancer.EntryProviderUpdated(mockProviderB);
        vault.setEntryProvider(mockProviderB);
    }

    // =========================================
    // setTimelock
    // =========================================

    function testSetTimelockRevertsIfCallerIsNotTimelock(
        address timelock
    ) public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setTimelock(timelock);
    }

    function testSetTimelockRevertsIfTimelockIsAddressZero() public {
        vm.expectRevert(IRebalancer.AddressZero.selector);
        vault.setTimelock(address(0));
    }

    function testSetTimelock(address timelock) public {
        vm.assume(timelock != address(0));
        vault.setTimelock(timelock);

        assertEq(vault.getTimelock(), timelock);
    }

    function testSetTimelockEmitsEvent(address timelock) public {
        vm.assume(timelock != address(0));

        vm.expectEmit(address(vault));
        emit IRebalancer.TimelockUpdated(timelock);
        vault.setTimelock(timelock);
    }

    // =========================================
    // setTreasury
    // =========================================

    function testSetTreasuryRevertsIfCallerIsNotAdmin(address treasury) public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setTreasury(treasury);
    }

    function testSetTreasuryRevertsIfTreasuryIsAddressZero() public {
        vm.expectRevert(IRebalancer.AddressZero.selector);
        vault.setTreasury(address(0));
    }

    function testSetTreasury(address treasury) public {
        vm.assume(treasury != address(0));
        vault.setTreasury(treasury);

        assertEq(vault.getTreasury(), treasury);
    }

    function testSetTreasuryEmitsEvents(address treasury) public {
        vm.assume(treasury != address(0));

        vm.expectEmit(address(vault));
        emit IRebalancer.FeesApplied(
            initialTotalAssets,
            initialTotalAssets,
            0,
            0
        );
        vm.expectEmit(address(vault));
        emit IRebalancer.TreasuryUpdated(treasury);
        vault.setTreasury(treasury);
    }

    // =========================================
    // setManagementFee
    // =========================================

    function testSetManagementFeeRevertsIfCallerIsNotAdmin(
        uint96 managementFee
    ) public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setManagementFee(managementFee);
    }

    function testSetManagementFeeRevertsIfFeeExceedsMax() public {
        uint96 managementFee = uint96(MAX_MANAGEMENT_FEE) + 1;
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setManagementFee(managementFee);
    }

    function testSetManagementFee(uint96 managementFee) public {
        vm.assume(managementFee <= MAX_MANAGEMENT_FEE);
        vault.setManagementFee(managementFee);

        assertEq(vault.getManagementFee(), managementFee);
    }

    function testSetManagementFeeEmitsEvents(uint96 managementFee) public {
        vm.assume(managementFee <= MAX_MANAGEMENT_FEE);

        vm.expectEmit(address(vault));
        emit IRebalancer.FeesApplied(
            initialTotalAssets,
            initialTotalAssets,
            0,
            0
        );
        vm.expectEmit(address(vault));
        emit IRebalancer.ManagementFeeUpdated(managementFee);
        vault.setManagementFee(managementFee);
    }

    // =========================================
    // setPerformanceFee
    // =========================================

    function testSetPerformanceFeeRevertsIfCallerIsNotAdmin(
        uint96 performanceFee
    ) public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setPerformanceFee(performanceFee);
    }

    function testSetPerformanceFeeRevertsIfFeeExceedsMax() public {
        uint96 performanceFee = uint96(MAX_PERFORMANCE_FEE) + 1;
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.setPerformanceFee(performanceFee);
    }

    function testSetPerformanceFee(uint96 performanceFee) public {
        vm.assume(performanceFee <= MAX_PERFORMANCE_FEE);
        vault.setPerformanceFee(performanceFee);

        assertEq(vault.getPerformanceFee(), performanceFee);
    }

    function testSetPerformanceFeeEmitsEvents(uint96 performanceFee) public {
        vm.assume(performanceFee <= MAX_PERFORMANCE_FEE);

        vm.expectEmit(address(vault));
        emit IRebalancer.FeesApplied(
            initialTotalAssets,
            initialTotalAssets,
            0,
            0
        );
        vm.expectEmit(address(vault));
        emit IRebalancer.PerformanceFeeUpdated(performanceFee);
        vault.setPerformanceFee(performanceFee);
    }

    // =========================================
    // setMinAssets
    // =========================================

    function testSetMinAssetsRevertsIfCallerIsNotAdmin(uint256 min) public {
        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.setMinAssets(min);
    }

    function testSetMinAssets(uint256 min) public {
        vault.setMinAssets(min);

        assertEq(vault.getMinAssets(), min);
    }

    function testSetMinAssetsEmitsEvent(uint256 min) public {
        vm.expectEmit(address(vault));
        emit IRebalancer.MinAssetsUpdated(min);
        vault.setMinAssets(min);
    }

    // =========================================
    // maxDeposit & maxMint
    // =========================================

    function testMaxDeposit() public {
        assertEq(vault.maxDeposit(alice), 0);
    }

    function testMaxMint() public {
        assertEq(vault.maxMint(alice), 0);
    }

    // =========================================
    // maxWithdraw & maxRedeem
    // =========================================

    function testMaxWithdraw() public {
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function testMaxRedeem() public {
        assertEq(vault.maxRedeem(alice), 0);
    }
}
