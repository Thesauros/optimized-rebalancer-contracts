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
    function testWithdrawTrace() public {
        address vaultAddr = vm.envAddress("VAULT");
        address user = vm.envAddress("DEPLOYER_ADDR");

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
