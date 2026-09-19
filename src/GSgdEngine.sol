// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {GSgd} from "./GSgd.sol";

/**
 * @title GSgdEngine
 * @author Garri Adrian Nablo
 *
 * @notice This is the implementation of the decentralized stablecoin engine.
 * The engine is responsible for maintaining a 1 token to SGD 1 peg.
 * This allows the stablecoin to have no governance, fees and to only be backed by ETH and BTC.
 *
 * The engine expects the token holders to always be overcollateralized.
 * Dipping below the threshold will result in automatic liquidation.
 * That is, the total of all collateral (ETH and BTC) should not be less than or equal to
 * the SGD value of all minted GSGD.
 *
 * This contract is the core of the GSGD stablecoin.
 * This same contract handles minting and redeeming GSGD, as well as depositing and withdrawing collateral.
 *
 * @notice During the course of development it was found out that this system is flawed.
 * The liquidation function assumes that users will be 200% overcollateralized.
 * A possible scenario would be if the price of a given collateral decreases then liquidators will not
 * be incentivized to liquidate users below the `MIN_HEALTH_FACTOR`.
 */
contract GSgdEngine is ReentrancyGuard {
    error GSgdEngine_ZeroAmount();
    error GSgdEngine_UnsupportedToken();
    error GSgdEngine_UnequalListOfSupportedTokensAndPriceFeeds();
    error GSgdEngine_TokenTransferFailed();
    error GSgdEngine_InvalidPrice();
    error GSgdEngine_BelowMinimumHealthFactor(uint256 healthFactor);
    error GSgdEngine_MintingFailed();
    error GSgdEngine_AboveMinimumHealthFactor(uint256 healthFactor);
    error GSgdEngine_Liquidation_FailedToImproveUnderCollateralizedUser(address undercollateralizedUser);
    error GSgdEngine_Liquidation_LiquidatorBelowThreshold(address liquidator);

    uint256 private constant PRECISION = 1e18;
    uint256 private constant PRECISION_DECIMALS = 18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% collateralization
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    mapping(address user => mapping(address token => uint256 coinAmount)) internal sUserCollateralBalances;
    mapping(address token => address priceFeed) private sPriceFeeds;
    mapping(address user => uint256 gSgdMinted) private sGSgdMinted;
    address[] private sSupportedTokenAddresses;
    address immutable I_GSGD;

    event CollateralDeposited(address indexed participant, address indexed tokenAddress, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed tokenAddress, uint256 amount
    );

    /**
     * @dev Check for non-zero values
     * @param amount - value to check
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert GSgdEngine_ZeroAmount();
        }
        _;
    }

    /**
     * @dev Check to only allow supported tokens
     * @param tokenAddress - address of the token
     */
    modifier supportedToken(address tokenAddress) {
        if (sPriceFeeds[tokenAddress] == address(0)) {
            revert GSgdEngine_UnsupportedToken();
        }
        _;
    }

    /**
     * @dev IMPORTANT: Make sure that that each supported token has an equivalent price feed oracle
     * @param tokenAddresses - list of supported ERC20 tokens
     * @param priceFeedAddresses - list of price feeds
     * @param stablecoinAddress - address of the GSGD smart contract
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address stablecoinAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert GSgdEngine_UnequalListOfSupportedTokensAndPriceFeeds();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address tokenAddress = tokenAddresses[i];
            sPriceFeeds[tokenAddress] = priceFeedAddresses[i];
            sSupportedTokenAddresses.push(tokenAddress);
        }

        I_GSGD = stablecoinAddress;
    }

    /**
     * @notice Deposits token to the engine as collateral
     * @param tokenCollateralAddress - supported token's address
     * @param collateralAmount - token amount collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        supportedToken(tokenCollateralAddress)
        nonReentrant
    {
        sUserCollateralBalances[msg.sender][tokenCollateralAddress] = collateralAmount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);

        // Send the collateral amount to this smart contract
        bool isTransferSuccess =
            IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!isTransferSuccess) {
            revert GSgdEngine_TokenTransferFailed();
        }
    }

    /**
     * @notice Creates stablecoin.
     * IMPORTANT: User has to have at least 200% collateral to be able to mint.
     * Otherwise the function reverts.
     * @param stablecoinAmountToMint - amount of GSGD to mint
     */
    function mintGSgd(uint256 stablecoinAmountToMint) public moreThanZero(stablecoinAmountToMint) nonReentrant {
        sGSgdMinted[msg.sender] += stablecoinAmountToMint;

        // Check if the user's collateral is still above or equal to 200% of the user's potential total GSGD amount
        _revertIfBelowMinHealthFactor(msg.sender);

        bool isMinted = GSgd(I_GSGD).mint(msg.sender, stablecoinAmountToMint);
        if (!isMinted) {
            revert GSgdEngine_MintingFailed();
        }
    }

    /**
     * @notice Convenience function that deposits collateral and mints GSGD for gas optimization
     * @param tokenCollateralAddress - supported token's address
     * @param collateralAmount - token amount collateral
     * @param stablecoinAmountToMint - amount of GSGD to mint
     */
    function depositCollateralAndMintGSgd(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 stablecoinAmountToMint
    ) public {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintGSgd(stablecoinAmountToMint);
    }

    /**
     * @notice Withdraws the calling user's deposited collateral token
     * IMPORTANT: User has to have at least 200% collateral after the transaction to be able withdraw the amount.
     * Otherwise the function reverts.
     * @param tokenCollateralAddress - supported token's address
     * @param collateralAmount - token amount collateral
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateralFrom(msg.sender, msg.sender, tokenCollateralAddress, collateralAmount);

        // Ensure the user's collateral is still above or equal to 200% after redeeming
        _revertIfBelowMinHealthFactor(msg.sender);
    }

    /**
     * @notice Convenience function that withdraws collateral and burns GSGD for gas optimization
     * @param tokenCollateralAddress - supported token's address
     * @param collateralAmount - token amount collateral
     * @param gSgdAmount - amount of GSGD tokens to burn
     */
    function redeemCollateralForGSgd(address tokenCollateralAddress, uint256 collateralAmount, uint256 gSgdAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        burnGSgd(gSgdAmount);
        redeemCollateral(tokenCollateralAddress, collateralAmount);
    }

    /**
     * @notice Burn GSGD
     * This allows users to manage their collateralization or health factor in the protocol
     * @param amount - amount of GSGD tokens to burn
     */
    function burnGSgd(uint256 amount) public moreThanZero(amount) {
        _burnGSgd(msg.sender, msg.sender, amount);
        _revertIfBelowMinHealthFactor(msg.sender);
    }

    /**
     * @notice This function is the heart-and-soul of this engine.
     * This allows and incentivizes liquidators to remove users
     * from their positions that are below the `LIQUIDATION_THRESHOLD`.
     * This helps in keeping the system in a health state and peg the GSGD to 1 USD.
     * @notice Users can partially liquidate a user.
     * A liquidation bonus will be given for completely paying off the user's debt.
     * @notice Users who attempt to liquidate a user but fail to improve the undercollateralized
     * user will cause the function to revert.
     * @param collateralTokenAddress - supported token's address
     * @param user - under collateralized user's wallet address
     * @param debtToCover - amount of GSGD to pay off
     */
    function liquidate(address collateralTokenAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingHealthFactor = _getHealthForUser(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert GSgdEngine_AboveMinimumHealthFactor(startingHealthFactor);
        }

        uint256 collateralRedeemed = getTokenAmountFromUsd(collateralTokenAddress, debtToCover);
        // A 10% liquidating bonus will be added on top of the `collateralRedeemed`
        // This is the incentive given to liquidators
        uint256 bonusCollateral = (collateralRedeemed * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 finalCollateralRedeemed = collateralRedeemed + bonusCollateral;
        _redeemCollateralFrom(user, msg.sender, collateralTokenAddress, finalCollateralRedeemed);
        _burnGSgd(user, msg.sender, debtToCover);

        uint256 endingHealthFactor = _getHealthForUser(user);
        if (endingHealthFactor <= LIQUIDATION_THRESHOLD) {
            revert GSgdEngine_Liquidation_FailedToImproveUnderCollateralizedUser(user);
        }

        uint256 liquidatorHealthFactor = _getHealthForUser(msg.sender);
        if (liquidatorHealthFactor <= LIQUIDATION_THRESHOLD) {
            revert GSgdEngine_Liquidation_LiquidatorBelowThreshold(msg.sender);
        }
    }

    /**
     * @notice Calculates the total collateral value in USD
     * @param user - address of the user
     * @return totalCollateralValueinUsd - total collateral value in USD
     */
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueinUsd) {
        for (uint256 i = 0; i < sSupportedTokenAddresses.length; i++) {
            address tokenAddress = sSupportedTokenAddresses[i];
            uint256 tokenAmount = sUserCollateralBalances[user][tokenAddress];
            totalCollateralValueinUsd += getTokenUsdValue(tokenAddress, tokenAmount);
        }
    }

    /**
     * @notice Calculates the USD value of a token
     * @param tokenAddress - ERC20 token address
     * @param amount - value of tokens in the lowest unit (e.g. Wei, Satoshi, etc)
     * @return usdValue - USD Value
     */
    function getTokenUsdValue(address tokenAddress, uint256 amount) public view returns (uint256 usdValue) {
        address priceFeedAddress = sPriceFeeds[tokenAddress];
        AggregatorV3Interface tokenPriceFeed = AggregatorV3Interface(priceFeedAddress);

        // NOTE: As of Sep 2026, most mainstream crypto currency will have a range from 6 - 18.
        // `price` will be the exchange rate value multiplied by the `priceDecimals`
        // `amount` will be in the crypto currency's lowest unit (e.g. Wei for ETH)
        // This means that the rate may be in a different decimal precision that the token amount.
        // For instance, assuming 1 ETH is USD 2497.97 then `price` is 249797000000 where `decimals` is 8.
        // 1 ETH is 1000000000000000000 Wei because ETH has 18 decimals.
        (, int256 price,,,) = tokenPriceFeed.latestRoundData();

        if (price <= 0) {
            revert GSgdEngine_InvalidPrice();
        }

        // To accurately get the USD value we need the `price` and `amount` in the same decimal precision
        uint256 priceDecimals = tokenPriceFeed.decimals();
        uint256 priceIn18Decimals = _convertValueTo18DecimalPrecision(uint256(price), priceDecimals);
        uint256 tokenDecimals = ERC20(tokenAddress).decimals();
        uint256 amountIn18Decimals = _convertValueTo18DecimalPrecision(amount, tokenDecimals);

        usdValue = (amountIn18Decimals * priceIn18Decimals) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmount) public view returns (uint256 tokenAmount) {
        address priceFeedAddress = sPriceFeeds[token];
        AggregatorV3Interface tokenPriceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = tokenPriceFeed.latestRoundData();
        uint256 priceDecimals = tokenPriceFeed.decimals();
        uint256 priceIn18Decimals = _convertValueTo18DecimalPrecision(uint256(price), priceDecimals);
        uint256 usdAmountIn18DecimalPrecision = _convertValueTo18DecimalPrecision(usdAmount, GSgd(I_GSGD).decimals());
        tokenAmount = usdAmountIn18DecimalPrecision / priceIn18Decimals;
    }

    /**
     * @notice Getter function to fetch a user's total GSGD minted and collateral in USD
     * @param user - address of the user from which to get information on
     * @return totalGSgdMinted - total GSGD minted
     * @return totalCollateralValueinUsd - USD value of total GSGD minted
     */
    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalGSgdMinted, uint256 totalCollateralValueinUsd)
    {
        totalGSgdMinted = sGSgdMinted[user];
        totalCollateralValueinUsd = getAccountCollateralValueInUsd(user);
    }

    /**
     * @notice Checks how close to liquidation a user is
     */
    function getHealthForUser() public view returns (uint256) {
        return _getHealthForUser(msg.sender);
    }

    function getSystemHealth() public {}

    /**
     * @dev Converts a value to another value with 18 decimal precision
     * @param value - uint256 value to be converted
     * @param decimals - number of decimals the value is currently at
     * @return valueIn18Decimals - a value in 18 decimal precision
     */
    function _convertValueTo18DecimalPrecision(uint256 value, uint256 decimals)
        private
        pure
        returns (uint256 valueIn18Decimals)
    {
        // We first get the difference in decimal precisions
        // IMPORTANT: Theoretically it is possible that `decimals` will be above 18.
        // This risk is mitigated by only supporting mainstream crypto currencies.
        uint256 additionalPrecision = 10 ** (PRECISION_DECIMALS - decimals);
        valueIn18Decimals = (value * additionalPrecision);
    }

    /**
     * @dev If the user is below the `LIQUIDATION_THRESHOLD`, they can be liquidated.
     * @param user - address of the user being checked
     */
    function _getHealthForUser(address user) private view returns (uint256) {
        (uint256 totalGSgdMinted, uint256 totalCollateralValueinUsd) = getAccountInformation(user);

        // If the user has not yet minted any GSGD we simply return the threshold to indicate a healthy state
        if (totalGSgdMinted == 0) {
            return LIQUIDATION_THRESHOLD;
        }

        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueinUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        uint256 collateralIn18Decimals = collateralAdjustedForThreshold * ERC20(I_GSGD).decimals();
        return collateralIn18Decimals / totalGSgdMinted;
    }

    /**
     * @dev Checks the Health Factor of a user
     * This will revert if below the `MIN_HEALTH_FACTOR` (i.e. 1)
     * @param user address of the user being checked
     */
    function _revertIfBelowMinHealthFactor(address user) private view {
        uint256 healthFactor = _getHealthForUser(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert GSgdEngine_BelowMinimumHealthFactor(healthFactor);
        }
    }

    /**
     * @dev This is a low-level private function
     * This function is also used in liquidating undercollateralized users
     * @param from - source wallet address where the collateral is taken
     * @param to - destination wallet address
     * @param tokenCollateralAddress - supported token's address
     * @param collateralAmount - token amount collateral
     */
    function _redeemCollateralFrom(address from, address to, address tokenCollateralAddress, uint256 collateralAmount)
        private
    {
        // NOTE: Solidity handles unsafe arithmetic operations
        // If the user tries to redeem more than they have (e.g. 10 - 100), Solidity will auto-revert
        sUserCollateralBalances[from][tokenCollateralAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, collateralAmount);

        // Takes the collateral amount from the `from` user to the `to` user
        bool isTransferSuccess = IERC20(tokenCollateralAddress).transfer(to, collateralAmount);
        if (!isTransferSuccess) {
            revert GSgdEngine_TokenTransferFailed();
        }
    }

    /**
     * @dev This is a low-level private function
     * Make sure the function calling this is checking ``
     * and ``'s health factor after.
     * @param owner - the owner of the GSGD to burn
     * @param from - GSGD address where the tokens will be taken
     * This may be different from the `owner` parameter if used when for liquidation.
     * @param amountToBurn - amount of tokens to burn
     */
    function _burnGSgd(address owner, address from, uint256 amountToBurn) public moreThanZero(amountToBurn) {
        // Decrease the owner's token balance
        sGSgdMinted[owner] -= amountToBurn;

        // Actual burning of tokens
        GSgd(I_GSGD).burn(from, amountToBurn);
    }
}
