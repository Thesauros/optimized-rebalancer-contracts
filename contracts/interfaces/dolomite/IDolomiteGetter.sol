// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.23;

import {IDolomiteMargin} from "./IDolomiteMargin.sol";

/**
 * @title IDolomiteGetter
 * @dev Modified version of the original Dolomite interface.
 */
interface IDolomiteGetter {
    function getMarketSupplyInterestRateApr(
        address _token
    ) external view returns (IDolomiteMargin.InterestRate memory);
}
