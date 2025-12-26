// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {MockingUtilities} from "../utils/MockingUtilities.sol";

contract RebalancerPermitTests is MockingUtilities {
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

    function setUp() public {
        (owner, ownerKey) = makeAddrAndKey("owner");

        initializeVault(vault, MIN_AMOUNT, initializer);
    }

    // =========================================
    // permit & redeem
    // =========================================

    function testRedeemWithPermit(
        uint128 mintAmount,
        uint128 redeemAmount
    ) public {
        vm.assume(
            mintAmount >= MIN_AMOUNT &&
                redeemAmount > 0 &&
                redeemAmount < mintAmount
        );

        executeMint(vault, mintAmount, owner);

        Permit memory permit = Permit({
            owner: owner,
            spender: spender,
            value: redeemAmount,
            nonce: vault.nonces(owner),
            deadline: block.timestamp + 1 days
        });

        bytes32 structHash = getStructHash(permit);
        bytes32 digest = getHashTypedDataV4(
            vault.DOMAIN_SEPARATOR(), // This domain should be from the chain where the state changes
            structHash
        );

        // This message signing is supposed to be off-chain
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

        assertEq(vault.allowance(owner, spender), redeemAmount);

        uint256 withdrawAmount = vault.previewRedeem(redeemAmount);
        uint256 fee = (withdrawAmount * WITHDRAW_FEE_PERCENT) /
            PRECISION_FACTOR;
        uint256 assetBalance = withdrawAmount - fee;

        vm.prank(spender);
        vault.redeem(redeemAmount, spender, owner);

        assertEq(vault.balanceOf(owner), mintAmount - redeemAmount);
        assertEq(asset.balanceOf(spender), assetBalance);
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
