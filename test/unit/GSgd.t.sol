// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {console, Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {GSgd} from "../../src/GSgd.sol";
import {GSgdEngine} from "../../src/GSgdEngine.sol";
import {GSgdDeploy} from "../../script/GSgd.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract GSgdEngineTest is Test {
    address STABLECOIN_USER = makeAddr("mockUser");
    GSgd gSgd;
    uint256 constant MOCK_WETH_AMOUNT = 10e18;

    function setUp() external {
        gSgd = new GSgd();
    }

    function test_mint() external {
        assertEq(gSgd.balanceOf(STABLECOIN_USER), 0);

        gSgd.mint(STABLECOIN_USER, 1);
        assertEq(gSgd.balanceOf(STABLECOIN_USER), 1);
    }

    function test_burn() external {
        gSgd.mint(STABLECOIN_USER, 1);
        assertEq(gSgd.balanceOf(STABLECOIN_USER), 1);

        gSgd.burn(STABLECOIN_USER, uint256(1));
        assertEq(gSgd.balanceOf(STABLECOIN_USER), 0);
    }
}
