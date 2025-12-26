// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ProviderManager} from "../../contracts/providers/ProviderManager.sol";
import {MockingUtilities} from "../utils/MockingUtilities.sol";

contract ProviderManagerTests is MockingUtilities {
    event YieldTokenUpdated(
        string identifier,
        address indexed asset,
        address yieldToken
    );

    event MarketUpdated(
        string identifier,
        address indexed assetOne,
        address indexed assetTwo,
        address market
    );

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
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vm.prank(alice);
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
        vm.expectEmit();
        emit YieldTokenUpdated(identifier, asset, yieldToken);
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
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vm.prank(alice);
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
        vm.expectEmit();
        emit MarketUpdated(identifier, assetOne, assetTwo, market);
        providerManager.setMarket(identifier, assetOne, assetTwo, market);
    }
}
