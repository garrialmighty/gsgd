// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {GSgd} from "../src/GSgd.sol";
import {GSgdEngine} from "../src/GSgdEngine.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

abstract contract Constants {
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant ANVIL_CHAIN_ID = 31337;
    uint8 public constant DECIMALS = 8;
    int256 public constant WETH_USD_EXCHANGE_RATE = 2480e8;
    int256 public constant WBTC_USD_EXCHANGE_RATE = 79000e8;
    int256 public constant USDC_USD_EXCHANGE_RATE = 1;
}

contract HelperConfig is Script, Constants {
    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address weth;
        address wethUsdPriceFeed;
        address wbtc;
        address wbtcUsdPriceFeed;
        address usdc;
        address usdcUsdPriceFeed;
        uint256 deployerKey;
    }

    constructor() {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() private pure returns (NetworkConfig memory sepoliaConfig) {
        // Values taken from https://docs.chain.link/vrf/v2-5/supported-networks
        sepoliaConfig = NetworkConfig({
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtc: 0x29f2D40B0605204364af54EC677bD022dA425d03,
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
            usdcUsdPriceFeed: 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E,
            deployerKey: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
        });
    }

    function getAnvilEthConfig() private returns (NetworkConfig memory anvilConfig) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator mockWethUsdPriceFeed = new MockV3Aggregator(DECIMALS, WETH_USD_EXCHANGE_RATE);
        ERC20Mock mockWeth = new ERC20Mock();

        MockV3Aggregator mockWbtcUsdPriceFeed = new MockV3Aggregator(DECIMALS, WBTC_USD_EXCHANGE_RATE);
        ERC20Mock mockWbtc = new ERC20Mock();

        MockV3Aggregator mockUsdcUsdPriceFeed = new MockV3Aggregator(DECIMALS, USDC_USD_EXCHANGE_RATE);
        ERC20Mock mockUsdc = new ERC20Mock();
        vm.stopBroadcast();

        anvilConfig = NetworkConfig({
            weth: address(mockWeth),
            wethUsdPriceFeed: address(mockWethUsdPriceFeed),
            wbtc: address(mockWbtc),
            wbtcUsdPriceFeed: address(mockWbtcUsdPriceFeed),
            usdc: address(mockUsdc),
            usdcUsdPriceFeed: address(mockUsdcUsdPriceFeed),
            deployerKey: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
        });
    }
}
