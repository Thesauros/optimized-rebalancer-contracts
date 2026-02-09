// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRebalancer} from "../../contracts/interfaces/IRebalancer.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";
import "../../contracts/libraries/Constants.sol";

contract RebalancerFeeTests is MockingBase {
    using Math for uint256;

    uint96 managementFee;
    uint96 performanceFee;

    function setUp() public override {
        super.setUp();

        managementFee = FIVE_PERCENT;
        performanceFee = TEN_PERCENT;

        vault.setManagementFee(managementFee);
        vault.setPerformanceFee(performanceFee);
    }

    // =========================================
    // applyFees
    // =========================================

    function testApplyFees(uint256 assets) public {
        assets = bound(assets, minAssets, maxTestAssets);

        _executeDeposit(vault, assets, alice);

        uint256 totalManagedAssetsBefore = initialTotalAssets + assets;

        skip(YEAR);

        uint256 yield = (totalManagedAssetsBefore * TEN_PERCENT) / SCALE;
        mockProtocolA.setInterest(yield);

        uint256 totalManagedAssetsAfter = totalManagedAssetsBefore + yield;

        uint256 performanceFeeAssets = yield.mulDiv(
            performanceFee,
            SCALE,
            Math.Rounding.Floor
        );
        uint256 managementFeeAssets = totalManagedAssetsAfter.mulDiv(
            managementFee,
            SCALE,
            Math.Rounding.Floor
        ); // dt == 365 days

        uint256 performanceFeeShares = performanceFeeAssets.mulDiv(
            vault.totalSupply(),
            totalManagedAssetsAfter -
                performanceFeeAssets -
                managementFeeAssets,
            Math.Rounding.Floor
        );
        uint256 managementFeeShares = managementFeeAssets.mulDiv(
            vault.totalSupply(),
            totalManagedAssetsAfter -
                performanceFeeAssets -
                managementFeeAssets,
            Math.Rounding.Floor
        );

        vault.applyFees();

        assertEq(vault.totalAssets(), totalManagedAssetsAfter);
        assertEq(vault.getLastTotalAssets(), totalManagedAssetsAfter);
        assertEq(vault.getLastTimestamp(), block.timestamp);

        uint256 sharesTreasury = vault.balanceOf(treasury);

        assertEq(sharesTreasury, performanceFeeShares + managementFeeShares);
        // rounding
        assertApproxEqAbs(
            vault.convertToAssets(sharesTreasury),
            managementFeeAssets + performanceFeeAssets,
            10
        );
    }

    function testApplyFeesEmitsEvent(uint256 assets) public {
        assets = bound(assets, minAssets, maxTestAssets);

        _executeDeposit(vault, assets, alice);

        uint256 totalManagedAssetsBefore = initialTotalAssets + assets;

        skip(YEAR);

        uint256 yield = (totalManagedAssetsBefore * TEN_PERCENT) / SCALE;
        mockProtocolA.setInterest(yield);

        uint256 totalManagedAssetsAfter = totalManagedAssetsBefore + yield;

        uint256 performanceFeeAssets = yield.mulDiv(
            performanceFee,
            SCALE,
            Math.Rounding.Floor
        );
        uint256 managementFeeAssets = totalManagedAssetsAfter.mulDiv(
            managementFee,
            SCALE,
            Math.Rounding.Floor
        ); // dt == 365 days

        uint256 performanceFeeShares = performanceFeeAssets.mulDiv(
            vault.totalSupply(),
            totalManagedAssetsAfter -
                performanceFeeAssets -
                managementFeeAssets,
            Math.Rounding.Floor
        );
        uint256 managementFeeShares = managementFeeAssets.mulDiv(
            vault.totalSupply(),
            totalManagedAssetsAfter -
                performanceFeeAssets -
                managementFeeAssets,
            Math.Rounding.Floor
        );

        vm.expectEmit(address(vault));
        emit IRebalancer.FeesApplied(
            totalManagedAssetsBefore,
            totalManagedAssetsAfter,
            performanceFeeShares,
            managementFeeShares
        );
        vault.applyFees();
    }

    // =========================================
    // getAccruedFees
    // =========================================

    function testAccruedFees(uint256 assets) public {
        assets = bound(assets, minAssets, maxTestAssets);

        _executeDeposit(vault, assets, alice);

        uint256 totalManagedAssetsBefore = initialTotalAssets + assets;

        skip(YEAR);

        uint256 yield = (totalManagedAssetsBefore * TEN_PERCENT) / SCALE;
        mockProtocolA.setInterest(yield);

        (uint256 performanceFeeShares, uint256 managementFeeShares) = vault
            .getAccruedFees();
        vault.applyFees();

        assertEq(
            vault.balanceOf(treasury),
            performanceFeeShares + managementFeeShares
        );
    }
}
