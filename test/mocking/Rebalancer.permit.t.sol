// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MockingBase} from "../mocking/MockingBase.t.sol";

contract RebalancerPermitTests is MockingBase {
    struct Permit {
        address owner;
        address spender;
        uint256 value;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

    address public spender = makeAddr("spender");
    address public operator = makeAddr("operator");

    address public owner;
    uint256 public ownerKey;

    function setUp() public override {
        super.setUp();

        (owner, ownerKey) = makeAddrAndKey("owner");
    }

    // =========================================
    // permit & redeem
    // =========================================

    function testRedeemWithPermit(uint256 shares) public {
        uint256 minShares = vault.convertToShares(minAssets); // explicit even if price is 1:1
        shares = bound(shares, minShares, maxTestShares);

        _executeMint(vault, shares, owner);

        Permit memory permit = Permit({
            owner: owner,
            spender: spender,
            value: shares,
            nonce: vault.nonces(owner),
            deadline: block.timestamp + 1 days
        });

        bytes32 structHash = getStructHash(permit);
        bytes32 digest = getHashTypedDataV4(
            vault.DOMAIN_SEPARATOR(), // this domain should be from the chain where the state changes
            structHash
        );

        // this message signing is supposed to be off-chain
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        vm.prank(operator);
        vault.permit(
            permit.owner,
            permit.spender,
            permit.value,
            permit.deadline,
            v,
            r,
            s
        );

        assertEq(vault.allowance(owner, spender), shares);

        vm.prank(spender);
        uint256 assets = vault.redeem(shares, spender, owner);

        assertEq(vault.balanceOf(owner), 0);
        assertEq(asset.balanceOf(spender), assets);
    }

    // =========================================
    // helpers
    // =========================================

    function getStructHash(
        Permit memory permit
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    PERMIT_TYPEHASH,
                    permit.owner,
                    permit.spender,
                    permit.value,
                    permit.nonce,
                    permit.deadline
                )
            );
    }

    function getHashTypedDataV4(
        bytes32 domainSeperator,
        bytes32 structHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19\x01", domainSeperator, structHash)
            );
    }
}
