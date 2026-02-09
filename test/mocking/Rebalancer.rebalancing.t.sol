// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IAccessManager} from "../../contracts/interfaces/IAccessManager.sol";
import {IProvider} from "../../contracts/interfaces/IProvider.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {MockProvider} from "../../contracts/mocks/MockProvider.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";

contract RebalancerRebalancingTests is MockingBase {
    IProvider[] public sources;
    IProvider[] public destinations;

    function setUp() public override {
        super.setUp();

        _executeDeposit(vault, THOUSAND, alice);
        _executeDeposit(vault, THOUSAND, bob);

        sources.push(mockProviderA);
        destinations.push(mockProviderB);
    }

    // =========================================
    // rebalance
    // =========================================

    function testRebalanceRevertsIfCallerIsNotExecutor() public {
        uint256[] memory amounts = new uint256[](1);

        vm.prank(alice);
        vm.expectRevert(IAccessManager.Unauthorized.selector);
        vault.rebalance(amounts, sources, destinations);
    }

    function testRebalanceRevertsIfCountIsZero() public {
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(IRebalancer.InvalidCount.selector);
        vault.rebalance(amounts, sources, destinations);
    }

    function testRebalanceRevertsIfArraysMismatch() public {
        uint256[] memory amounts = new uint256[](1);
        IProvider[] memory invalidSources = new IProvider[](2);
        IProvider[] memory invalidDestinations = new IProvider[](0);

        vm.expectRevert(IRebalancer.ArrayMismatch.selector);
        vault.rebalance(amounts, invalidSources, destinations);

        vm.expectRevert(IRebalancer.ArrayMismatch.selector);
        vault.rebalance(amounts, sources, invalidDestinations);
    }

    function testRebalanceRevertsIfProviderIsInvalid() public {
        uint256[] memory amounts = new uint256[](1);

        IProvider[] memory invalidSources = new IProvider[](1);
        invalidSources[0] = mockProviderC;

        IProvider[] memory invalidDestinations = new IProvider[](1);
        invalidDestinations[0] = mockProviderC;

        vm.expectRevert(IRebalancer.InvalidProvider.selector);
        vault.rebalance(amounts, sources, invalidDestinations);

        vm.expectRevert(IRebalancer.InvalidProvider.selector);
        vault.rebalance(amounts, invalidSources, destinations);
    }

    function testRebalanceRevertsIfAssetsIsZero() public {
        uint256[] memory amounts = new uint256[](1);

        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.rebalance(amounts, sources, destinations);
    }

    function testRebalanceRevertsIfAssetsExceedsFrom() public {
        uint256[] memory amounts = new uint256[](1);

        amounts[0] = _getAssetsAtProvider(vault, mockProviderA) + 1;

        vm.expectRevert(IRebalancer.InvalidInput.selector);
        vault.rebalance(amounts, sources, destinations);
    }

    function testRebalanceWhenAssetsIsMax() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        uint256 assetsAtFrom = initialTotalAssets + (2 * THOUSAND);

        assertEq(_getAssetsAtProvider(vault, mockProviderA), assetsAtFrom);

        vault.rebalance(amounts, sources, destinations);

        assertEq(_getAssetsAtProvider(vault, mockProviderA), 0);
        assertEq(_getAssetsAtProvider(vault, mockProviderB), assetsAtFrom);
    }

    function testRebalance() public {
        uint256 assets = 2 * THOUSAND;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = assets;

        vault.rebalance(amounts, sources, destinations);

        assertEq(
            _getAssetsAtProvider(vault, mockProviderA),
            initialTotalAssets
        );
        assertEq(_getAssetsAtProvider(vault, mockProviderB), assets);
    }

    function testRebalanceEmitsEvent() public {
        uint256 assets = 2 * THOUSAND;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = assets;

        vm.expectEmit(address(vault));
        emit IRebalancer.RebalanceExecuted(
            assets,
            address(mockProviderA),
            address(mockProviderB)
        );
        vault.rebalance(amounts, sources, destinations);
    }
}
