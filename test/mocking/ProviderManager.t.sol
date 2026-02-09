// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProviderManager} from "../../contracts/interfaces/IProviderManager.sol";
import {ProviderManager} from "../../contracts/utils/ProviderManager.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";

contract ProviderManagerTests is MockingBase {
    ProviderManager public providerManager;

    function setUp() public override {
        providerManager = new ProviderManager(address(this));
    }

    // =========================================
    // constructor
    // =========================================

    function testConstructor() public view {
        assertEq(providerManager.owner(), address(this));
    }

    // =========================================
    // setYieldToken
    // =========================================

    function testSetYieldTokenRevertsIfCallerIsNotOwner(
        string memory identifier,
        address asset,
        address yieldToken
    ) public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        providerManager.setYieldToken(identifier, asset, yieldToken);
    }

    function testSetYieldToken(
        string memory identifier,
        address asset,
        address yieldToken
    ) public {
        providerManager.setYieldToken(identifier, asset, yieldToken);

        string[] memory providerIdentifiers = providerManager.getIdentifiers();

        assertEq(providerIdentifiers[0], identifier);
        assertEq(providerManager.getYieldToken(identifier, asset), yieldToken);
    }

    function testSetYieldTokenEmitsEvent(
        string memory identifier,
        address asset,
        address yieldToken
    ) public {
        vm.expectEmit(address(providerManager));
        emit IProviderManager.YieldTokenUpdated(identifier, asset, yieldToken);
        providerManager.setYieldToken(identifier, asset, yieldToken);
    }

    // =========================================
    // setMarket
    // =========================================

    function testSetMarketRevertsIfCallerIsNotOwner(
        string memory identifier,
        address assetOne,
        address assetTwo,
        address market
    ) public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        providerManager.setMarket(identifier, assetOne, assetTwo, market);
    }

    function testSetMarket(
        string memory identifier,
        address assetOne,
        address assetTwo,
        address market
    ) public {
        providerManager.setMarket(identifier, assetOne, assetTwo, market);

        string[] memory providerIdentifiers = providerManager.getIdentifiers();

        assertEq(providerIdentifiers[0], identifier);
        assertEq(
            providerManager.getMarket(identifier, assetOne, assetTwo),
            market
        );
    }

    function testSetMarketEmitsEvent(
        string memory identifier,
        address assetOne,
        address assetTwo,
        address market
    ) public {
        vm.expectEmit(address(providerManager));
        emit IProviderManager.MarketUpdated(
            identifier,
            assetOne,
            assetTwo,
            market
        );
        providerManager.setMarket(identifier, assetOne, assetTwo, market);
    }
}
