// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TronTUSDT is ERC20 {
    error Unauthorized();

    address public immutable gateway;
    uint8 private immutable _tokenDecimals;

    modifier onlyGateway() {
        _checkGateway();
        _;
    }

    constructor(
        address gateway_,
        uint8 decimals_
    ) ERC20("Thesauros USDT", "tUSDT") {
        gateway = gateway_;
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address receiver, uint256 shares) external onlyGateway {
        _mint(receiver, shares);
    }

    function burn(uint256 shares) external onlyGateway {
        _burn(gateway, shares);
    }

    function _checkGateway() private view {
        if (msg.sender != gateway) revert Unauthorized();
    }
}
