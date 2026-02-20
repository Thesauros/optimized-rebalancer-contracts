// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

contract MockProtocol {
    MockERC20 private immutable _asset;

    mapping(address => uint256) private _balances;

    uint256 private _interest;

    constructor(MockERC20 asset_) {
        _asset = asset_;
    }

    function supply(uint256 amount, address receiver) external {
        _asset.transferFrom(msg.sender, address(this), amount);
        _balances[receiver] += amount;
    }

    function withdraw(uint256 amount, address receiver) external {
        _balances[msg.sender] -= amount;
        _asset.transfer(receiver, amount);
    }

    function setInterest(uint256 interest) external {
        _interest = interest;
    }

    function balances(address user) external view returns (uint256) {
        return _balances[user] + _interest;
    }
}
