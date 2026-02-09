// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ITransparentUpgradeableProxy, IERC1967} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockRebalancerV2} from "../../contracts/mocks/MockRebalancerV2.sol";
import {MockingBase} from "../mocking/MockingBase.t.sol";

contract RebalancerUpgradeabilityTests is MockingBase {
    MockRebalancerV2 public implementationV2;
    ProxyAdmin public proxyAdmin;

    function setUp() public override {
        super.setUp();

        implementationV2 = new MockRebalancerV2();
        proxyAdmin = ProxyAdmin(_getProxyAdmin());
    }

    // =========================================
    // initialize
    // =========================================

    function testInitializeRevertsOnImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(
            address(this),
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

    function testInitializeRevertsOnImplementationV2() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV2.initialize(
            address(this),
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
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV2.initializeV2();
    }

    // =========================================
    // upgradeAndCall
    // =========================================

    function testUpgradeAndCallRevertsIfCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implementationV2),
            ""
        );
    }

    function testUpgradeAndCall() public {
        address oldImplementation = _getImplementation();

        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implementationV2),
            ""
        );

        address newImplementation = _getImplementation();

        assertTrue(oldImplementation != newImplementation);
        assertEq(newImplementation, address(implementationV2));
    }

    function testUpgradeAndCallDoesNotModifyUserState() public {
        _executeDeposit(vault, HUNDRED, alice);
        skip(DAY);
        _executeWithdraw(vault, HUNDRED, alice);
        skip(DAY);
        _executeDeposit(vault, THOUSAND, alice);
        _executeDeposit(vault, THOUSAND, bob);

        uint256 sharesAliceBefore = vault.balanceOf(alice);
        uint256 sharesBobBefore = vault.balanceOf(bob);
        uint256 previewedAliceBefore = vault.previewRedeem(sharesAliceBefore);
        uint256 previewedBobBefore = vault.previewRedeem(sharesBobBefore);
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 totalManagedAssetsBefore = vault.totalAssets();

        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implementationV2),
            ""
        );

        assertEq(vault.balanceOf(alice), sharesAliceBefore);
        assertEq(vault.balanceOf(bob), sharesBobBefore);
        assertEq(vault.previewRedeem(sharesAliceBefore), previewedAliceBefore);
        assertEq(vault.previewRedeem(sharesBobBefore), previewedBobBefore);
        assertEq(vault.totalSupply(), totalSupplyBefore);
        assertEq(vault.totalAssets(), totalManagedAssetsBefore);
    }

    function testUpgradeAndCallEmitsEvents() public {
        bytes memory data = abi.encodeWithSelector(
            MockRebalancerV2.initializeV2.selector
        );

        vm.expectEmit(address(proxy));
        emit IERC1967.Upgraded(address(implementationV2));
        vm.expectEmit(address(proxy));
        emit Initializable.Initialized(2);

        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(implementationV2),
            data
        );
    }

    // =========================================
    // helpers
    // =========================================

    function _getImplementation() internal view returns (address) {
        bytes32 implementation = vm.load(
            address(proxy),
            ERC1967Utils.IMPLEMENTATION_SLOT
        );
        return address(uint160(uint256(implementation)));
    }

    function _getProxyAdmin() internal view returns (address) {
        bytes32 admin = vm.load(address(proxy), ERC1967Utils.ADMIN_SLOT);
        return address(uint160(uint256(admin)));
    }
}
