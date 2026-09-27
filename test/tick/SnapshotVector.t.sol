// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {NavSnapshot} from "../../contracts/tick/NavSnapshot.sol";

contract SnapshotHasher {
    function hash(NavSnapshot.Snapshot calldata s) external pure returns (bytes32) {
        return NavSnapshot.hash(s);
    }
}

/**
 * @notice Shared test vector: the ops NAV engine (ops/test/snapshot.test.ts)
 *         must produce the same hash for the same snapshot. If either side's
 *         encoding changes, one of the two tests fails.
 */
contract SnapshotVectorTest is Test {
    bytes32 internal constant EXPECTED = 0xcb6fb2dc96d2af5a545b88e19827738167ff81c6f8b7447ec490b6fb341e71b5;

    function vector() public pure returns (NavSnapshot.Snapshot memory s) {
        s.version = 1;
        s.tickId = 7;
        s.referenceTime = 1_800_000_000;
        s.chains = new NavSnapshot.ChainRef[](2);
        s.chains[0] = NavSnapshot.ChainRef(8453, 30_000_000, bytes32(uint256(0xb1)));
        s.chains[1] = NavSnapshot.ChainRef(42161, 250_000_000, bytes32(uint256(0xa1)));
        s.positions = new NavSnapshot.Position[](2);
        s.positions[0] = NavSnapshot.Position(8453, address(0x1111), address(0), 0, 5e6, 5e6, 5e6);
        s.positions[1] = NavSnapshot.Position(42161, address(0x2222), address(0x3333), 1, 9e6, 10e6, 10e6);
        s.inFlight = new NavSnapshot.InFlight[](1);
        s.inFlight[0] = NavSnapshot.InFlight(bytes32(uint256(0xfeed)), 8453, 42161, 1_799_999_000, 3e6, 2_990_000, 0);
        s.hubCash = 1e6;
        s.pendingDeposits = 2e5;
        s.liabilities = 1e5;
        s.totalShares = 18e6;
    }

    function testVectorHash() public {
        bytes32 h = new SnapshotHasher().hash(vector());
        emit log_named_bytes32("snapshot vector hash", h);
        assertEq(h, keccak256(abi.encode(vector())), "calldata hash == memory abi.encode hash");
        assertEq(h, EXPECTED, "vector hash pinned (update ops/test/snapshot.test.ts too)");
    }
}
