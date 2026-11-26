// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ForkingBase} from "./ForkingBase.t.sol";
import {console} from "forge-std/console.sol";

interface IVault {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function getLastTotalAssets() external view returns (uint256);
    function getLastTimestamp() external view returns (uint64);
    function previewWithdraw(uint256) external view returns (uint256);
    function withdraw(uint256, address, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function applyFees() external;
}

contract NewVaultWithdrawTest is ForkingBase {
    /// An operator trace, not an assertion: it prints one vault's withdrawal state and then
    /// performs the withdrawal against a caller supplied from the environment. Both addresses
    /// have to be given, so without them the file is skipped rather than failing. Reading them
    /// with `vm.envAddress` made `forge test --match-path 'test/forking/*'` red on every run
    /// that did not happen to be a withdrawal investigation, and CI excludes forking tests, so
    /// nothing surfaced it.
    ///
    ///   VAULT=0x... DEPLOYER_ADDR=0x... forge test \
    ///     --match-contract NewVaultWithdrawTest -vvvv
    function testWithdrawTrace() public {
        address vaultAddr = vm.envOr("VAULT", address(0));
        address user = vm.envOr("DEPLOYER_ADDR", address(0));
        vm.skip(vaultAddr == address(0) || user == address(0));

        IVault v = IVault(vaultAddr);
        console.log("user shares:", v.balanceOf(user));
        console.log("totalSupply:", v.totalSupply());
        console.log("totalAssets:", v.totalAssets());
        console.log("lastTotalAssets:", v.getLastTotalAssets());
        console.log("lastTimestamp:", v.getLastTimestamp());
        console.log("previewWithdraw(1e6):", v.previewWithdraw(1e6));

        vm.prank(user);
        v.withdraw(1e6, user, user);
    }
}
