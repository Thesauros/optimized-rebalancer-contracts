// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CctpV2Adapter} from "../../contracts/crosschain/bridges/CctpV2Adapter.sol";

/**
 * @title CctpV2AdapterRemotesTest
 * @notice Domain<->chain mapping rules in `setRemote`.
 *
 * @dev `finalize` resolves a source chain only through `chainIdOfDomain`, so a domain claimed
 *      by two chains misattributes every burn from that domain. These are unit tests rather
 *      than fork tests because the guard is about the registry, not about Circle's contracts:
 *      the messenger and transmitter only need to have code for the constructor to accept them.
 *
 *      Domain 0 is a live value (Circle's Ethereum mainnet domain) and is also what an unset
 *      `uint64` mapping entry reads as. The two stay distinguishable only because `setRemote`
 *      rejects `chainId == 0`, so a zero mapping entry always means "unclaimed".
 */
contract CctpV2AdapterRemotesTest is Test {
    uint64 internal constant BASE = 8453;
    uint64 internal constant ARBITRUM = 42161;
    uint64 internal constant ETHEREUM = 1;

    uint32 internal constant DOMAIN_BASE = 6;
    uint32 internal constant DOMAIN_ARBITRUM = 3;
    uint32 internal constant DOMAIN_ETHEREUM = 0;
    /// @dev a domain no real chain uses, for the re-pointing case
    uint32 internal constant DOMAIN_OTHER = 7;

    address internal constant ASSET = address(0xA55E7);
    address internal constant AGENT = address(0xA6E47);
    address internal constant MESSENGER = address(0xE55E47);
    address internal constant TRANSMITTER = address(0x7A445E17);
    address internal constant PEER_ARBITRUM = address(0xA4B1744);
    address internal constant PEER_ARBITRUM_NEXT = address(0xA4B1745);
    address internal constant PEER_ETHEREUM = address(0xE7F1);

    /// @dev mirrors CctpV2Adapter.RemoteDomainCleared so `expectEmit` can match it
    event RemoteDomainCleared(uint64 indexed chainId, uint32 stale);

    CctpV2Adapter internal adapter;

    function setUp() public {
        vm.etch(MESSENGER, hex"6000");
        vm.etch(TRANSMITTER, hex"6000");
        // the adapter's own chain id must differ from every remote it registers
        vm.chainId(BASE);
        adapter = new CctpV2Adapter(ASSET, AGENT, address(this), MESSENGER, TRANSMITTER, 2000);
    }

    function testRegistersDistinctDomains() public {
        adapter.setRemote(ARBITRUM, DOMAIN_ARBITRUM, PEER_ARBITRUM);
        adapter.setRemote(ETHEREUM, DOMAIN_ETHEREUM, PEER_ETHEREUM);

        assertEq(adapter.chainIdOfDomain(DOMAIN_ARBITRUM), ARBITRUM);
        assertEq(adapter.chainIdOfDomain(DOMAIN_ETHEREUM), ETHEREUM);

        (uint32 ethDomain, address ethAdapter, bool ethSet) = adapter.remotes(ETHEREUM);
        assertEq(ethDomain, DOMAIN_ETHEREUM);
        assertEq(ethAdapter, PEER_ETHEREUM);
        assertTrue(ethSet);
    }

    /// @dev A domain already claimed by another chain must not be silently reassigned: the
    ///      previous holder's burns would then be attributed to the new one.
    function testRejectsASecondChainClaimingAMappedDomain() public {
        adapter.setRemote(ETHEREUM, DOMAIN_ETHEREUM, PEER_ETHEREUM);

        vm.expectRevert(
            abi.encodeWithSelector(CctpV2Adapter.DomainAlreadyMapped.selector, ETHEREUM, DOMAIN_ETHEREUM)
        );
        adapter.setRemote(ARBITRUM, DOMAIN_ETHEREUM, PEER_ARBITRUM);

        // the rejected registration left no trace
        (, , bool arbSet) = adapter.remotes(ARBITRUM);
        assertFalse(arbSet);
        assertEq(adapter.chainIdOfDomain(DOMAIN_ETHEREUM), ETHEREUM);
    }

    function testRejectsCollisionOnANonZeroDomain() public {
        adapter.setRemote(ARBITRUM, DOMAIN_ARBITRUM, PEER_ARBITRUM);

        vm.expectRevert(
            abi.encodeWithSelector(CctpV2Adapter.DomainAlreadyMapped.selector, ARBITRUM, DOMAIN_ARBITRUM)
        );
        adapter.setRemote(ETHEREUM, DOMAIN_ARBITRUM, PEER_ETHEREUM);
    }

    /// @dev Re-pointing the same chain at a new peer adapter is the ordinary upgrade path and
    ///      must keep working under the same domain.
    function testAllowsRepointingTheSameChainUnderTheSameDomain() public {
        adapter.setRemote(ARBITRUM, DOMAIN_ARBITRUM, PEER_ARBITRUM);
        adapter.setRemote(ARBITRUM, DOMAIN_ARBITRUM, PEER_ARBITRUM_NEXT);

        (uint32 domain, address peerAdapter, bool set) = adapter.remotes(ARBITRUM);
        assertEq(domain, DOMAIN_ARBITRUM);
        assertEq(peerAdapter, PEER_ARBITRUM_NEXT);
        assertTrue(set);
        assertEq(adapter.chainIdOfDomain(DOMAIN_ARBITRUM), ARBITRUM);
    }

    /// @dev Moving a chain to a new domain must not leave the old one resolving to it: that
    ///      mapping would otherwise only fail late, on the `r.domain != sourceDomain` check.
    function testRepointingToANewDomainClearsTheStaleMapping() public {
        adapter.setRemote(ARBITRUM, DOMAIN_ARBITRUM, PEER_ARBITRUM);

        vm.expectEmit(true, false, false, true);
        emit RemoteDomainCleared(ARBITRUM, DOMAIN_ARBITRUM);
        adapter.setRemote(ARBITRUM, DOMAIN_OTHER, PEER_ARBITRUM);

        assertEq(adapter.chainIdOfDomain(DOMAIN_ARBITRUM), 0, "stale domain still resolves");
        assertEq(adapter.chainIdOfDomain(DOMAIN_OTHER), ARBITRUM);

        // the freed domain can now be claimed by the chain that actually owns it
        adapter.setRemote(ETHEREUM, DOMAIN_ARBITRUM, PEER_ETHEREUM);
        assertEq(adapter.chainIdOfDomain(DOMAIN_ARBITRUM), ETHEREUM);
    }

    function testOnlyGovernanceSetsRemotes() public {
        vm.prank(AGENT);
        vm.expectRevert(CctpV2Adapter.Unauthorized.selector);
        adapter.setRemote(ARBITRUM, DOMAIN_ARBITRUM, PEER_ARBITRUM);
    }

    function testRejectsOwnChainIdAndZeroValues() public {
        vm.expectRevert(CctpV2Adapter.InvalidConfig.selector);
        adapter.setRemote(BASE, DOMAIN_BASE, PEER_ARBITRUM);

        vm.expectRevert(CctpV2Adapter.InvalidConfig.selector);
        adapter.setRemote(0, DOMAIN_ARBITRUM, PEER_ARBITRUM);

        vm.expectRevert(CctpV2Adapter.InvalidConfig.selector);
        adapter.setRemote(ARBITRUM, DOMAIN_ARBITRUM, address(0));
    }
}
