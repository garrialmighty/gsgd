// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GSGD
 * @author Garri Adrian Nablo
 *
 * @notice This is the ERC20 implementation of the stablecoin.
 * This will be governed by the GSGDEngine.
 * Collateral: WETH, WBTC, USDC
 * Minting: Algorithmic
 * Stability: Pegged to SGD
 *
 */
contract GSgd is ERC20, Ownable {
    error GSgd_BurnZeroAmount();
    error GSgd_InsufficientBalanceToBurn();
    error GSgd_ZeroAddress();
    error GSgd_MintZeroAmount();

    constructor() ERC20("GSGD", "GSGD") Ownable(msg.sender) {}

    /**
     * @notice Creates a `value` amount of tokens and assigns them to `account`
     * @param account - token owner's wallet address
     * @param value - amount of tokens to create
     */
    function mint(address account, uint256 value) external onlyOwner returns (bool) {
        if (account == address(0)) {
            revert GSgd_ZeroAddress();
        }

        if (value <= 0) {
            revert GSgd_MintZeroAmount();
        }
        _mint(account, value);
        return true;
    }

    /**
     * @notice Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * @param account - token owner's wallet address where the amount of token to burn comes from
     * @param value - amount of tokens to destroy
     */
    function burn(address account, uint256 value) external onlyOwner {
        uint256 balance = balanceOf(account);

        if (value <= 0) {
            revert GSgd_BurnZeroAmount();
        }

        if (balance < value) {
            revert GSgd_InsufficientBalanceToBurn();
        }

        super._burn(account, value);
    }
}
