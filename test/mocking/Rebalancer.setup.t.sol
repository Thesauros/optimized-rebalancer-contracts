// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {Rebalancer} from "../../contracts/Rebalancer.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";

contract RebalancerSetupTests is MockingBase {
    
    // =========================================
    // initialize
    // =========================================

    function testInitializeRevertsIfAdminIsAddressZero() public {
        (, , Rebalancer otherVault) = _deployVault();
        vm.expectRevert(IRebalancer.AddressZero.selector);
        otherVault.initialize(
            address(0),
            address(this),
            address(asset),
            NAME,
            SYMBOL,
            providers,
            treasury,
            0,
            0,
            minAssets
        );
    }

    function testInitializeRevertsIfAssetIsAddressZero() public {
        (, , Rebalancer otherVault) = _deployVault();
        vm.expectRevert(IRebalancer.AddressZero.selector);
        otherVault.initialize(
            address(this),
            address(this),
            address(0),
            NAME,
            SYMBOL,
            providers,
            treasury,
            0,
            0,
            minAssets
        );
    }

    function testInitializeRevertsIfMinAssetsIsZero() public {
        (, , Rebalancer otherVault) = _deployVault();
        vm.expectRevert(IRebalancer.InvalidInput.selector);
        otherVault.initialize(
            address(this),
            address(this),
            address(asset),
            NAME,
            SYMBOL,
            providers,
            treasury,
            0,
            0,
            0
        );
    }

    function testInitialize() public {
        assertTrue(vault.hasRole(ADMIN_ROLE, address(this)));
        assertEq(vault.asset(), address(asset));
        assertEq(vault.decimals(), ASSET_DECIMALS);
        assertEq(vault.name(), NAME);
        assertEq(vault.symbol(), SYMBOL);
        assertEq(vault.getTimelock(), address(this));
        assertEq(address(vault.getProviders()[0]), address(mockProviderA));
        assertEq(address(vault.getProviders()[1]), address(mockProviderB));
        assertEq(address(vault.getEntryProvider()), address(mockProviderA));
        assertEq(vault.getTreasury(), treasury);
        assertEq(vault.getManagementFee(), 0);
        assertEq(vault.getPerformanceFee(), 0);
        assertEq(vault.getMinAssets(), minAssets);
        assertEq(vault.getLastTimestamp(), block.timestamp);
        assertEq(vault.totalAssets(), initialTotalAssets);
        assertEq(vault.balanceOf(address(vault)), minAssets);
        assertEq(vault.getLastTotalAssets(), minAssets);
    }
}
