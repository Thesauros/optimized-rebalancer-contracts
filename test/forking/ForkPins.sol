// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title ForkPins
 * @notice The single place deciding which block each fork test replays.
 *
 * @dev An unpinned `createSelectFork(url)` floats at whatever the RPC reports as latest, so a
 *      green run says nothing about the next one: provider liquidity, exchange rates and every
 *      assertion built on them move underneath the test. Pinning fixes that — but only where an
 *      archive endpoint is reachable, so each default below records what was actually verified
 *      on 2026-11-11 rather than an aspiration:
 *
 *        BASE_FORK_BLOCK     pinned. `BASE_RPC_URL` (https://mainnet.base.org) serves
 *                            historical state, so the Base suite is reproducible as shipped.
 *        ETHEREUM_FORK_BLOCK floats. The configured `ETHEREUM_RPC_URL`
 *                            (https://ethereum-rpc.publicnode.com) answers archive requests
 *                            with HTTP 403 "Archive requests require a personal token", so a
 *                            pinned default would fail on the project's own setup.
 *        ARBITRUM_FORK_BLOCK floats. Neither https://arb1.arbitrum.io/rpc ("missing trie node"
 *                            / "historical state") nor a free archive endpoint served state at
 *                            any depth tested, down to head-50k.
 *
 *      To get a reproducible run, point the RPC at an archive endpoint and set the pin:
 *
 *        ETHEREUM_RPC_URL=https://eth.drpc.org ETHEREUM_FORK_BLOCK=26356000 \
 *          forge test --match-path 'test/forking/*'
 *
 *      `https://eth.drpc.org` served Ethereum archive state for free when this was written.
 *      A pin of 0 always means "float at latest", which is the pre-pinning behaviour.
 */
library ForkPins {
    /// @notice Env var naming the Base pin.
    string internal constant BASE_VAR = "BASE_FORK_BLOCK";
    /// @notice Env var naming the Ethereum pin.
    string internal constant ETHEREUM_VAR = "ETHEREUM_FORK_BLOCK";
    /// @notice Env var naming the Arbitrum pin.
    string internal constant ARBITRUM_VAR = "ARBITRUM_FORK_BLOCK";

    /// @notice Base block the suite was last verified green at (~5 days behind head 56_079_351).
    uint256 internal constant BASE = 55_863_000;
    /// @notice Ethereum floats; see the contract NatSpec for why.
    uint256 internal constant ETHEREUM = 0;
    /// @notice Arbitrum floats; see the contract NatSpec for why.
    uint256 internal constant ARBITRUM = 0;

    /**
     * @notice Forks and selects `url` at the pin from `pinVar`, falling back to `fallbackPin`.
     * @dev A resolved pin of 0 forks at the RPC's latest block.
     */
    function selectFork(
        Vm vm,
        string memory url,
        string memory pinVar,
        uint256 fallbackPin
    ) internal returns (uint256 forkId) {
        uint256 pin = vm.envOr(pinVar, fallbackPin);
        return pin == 0 ? vm.createSelectFork(url) : vm.createSelectFork(url, pin);
    }
}
