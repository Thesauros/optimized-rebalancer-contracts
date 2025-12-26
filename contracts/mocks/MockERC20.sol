// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 *
 * @dev This contract also handles provider-like
 * logic to allow tracking of token balances in testing.
 */
contract MockERC20 is ERC20 {
    event Deposit(string provider, address from, uint256 value);
    event Withdraw(string provider, address from, uint256 value);

    mapping(string => mapping(address => uint256)) private _depositBalance;

    uint8 private _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // mocking WETH
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    // mocking WETH
    function withdraw(uint256 value) public {
        _burn(msg.sender, value);
        payable(msg.sender).transfer(value);
    }

    function mint(address to, uint256 value) public {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public {
        _burn(from, value);
    }

    function depositTokens(
        address from,
        uint256 value,
        string memory provider
    ) public returns (bool success) {
        _depositBalance[provider][from] += value;
        _burn(from, value);
        emit Deposit(provider, from, value);
        success = true;
    }

    function withdrawTokens(
        address to,
        uint256 value,
        string memory provider
    ) public returns (bool success) {
        _depositBalance[provider][to] -= value;
        _mint(to, value);
        emit Withdraw(provider, to, value);
        success = true;
    }

    function depositBalance(
        address user,
        string memory provider
    ) public view returns (uint256) {
        return _depositBalance[provider][user];
    }
}
