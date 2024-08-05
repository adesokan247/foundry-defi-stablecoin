// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions
 
pragma solidity 0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author 0xadesokan247
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * -Exogeneous Callateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and wBTC.
 *
 * Our DSC system should alwasy be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all DSC.
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrwaing collateral.
*/

contract DSCEngine is ReentrancyGuard {
    //////////////////
    // Errors    /////
    //////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////////
    // Types             //
    ///////////////////////
    using OracleLib for AggregatorV3Interface;


    ///////////////////////
    // State Variables    //
    ///////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //this means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscToMint) private s_DSCMinted;
    address[] private s_collateralTokens;

    address weth;
    address wbtc;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////
    // Event        //
    //////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    /**
     * @dev Emitted when collateral is redeemed.
     * @param RedeemFrom The address from which the collateral is redeemed.
     * @param RedeemTo The address to which the collateral is redeemed.
     * @param token The address of the collateral token.
     * @param amount The amount of collateral redeemed.
     */
    event CollateralRedeemed(address indexed RedeemFrom, address indexed RedeemTo, address indexed token, uint256 amount);

    //////////////////
    // Modifiers    //
    //////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //////////////////
    // Functions    //
    //////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength();
        }
        // for example ETH / USD, BTC / USD, MKR / USD etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External Functions//
    //////////////////////

    /*
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stabecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     * 
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscMint);
    }

    /*
     * @notice follow CEI check effect interaction
     * @param tokenCollateralAddress The address of the token to deposit as collateral 
     * @param amountCollateral The amount of collateral to deposit
    
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }


    /**
     * 
     * @param tokenCollateralAddress The collateral address to redeem to
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of Dsc to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
       burnDsc(amountDscToBurn);
       redeemCollateral(tokenCollateralAddress, amountCollateral);
    //    redeemCollateral already checks health factor


    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled
    // DRY: Don't repeate yourself

    // CEI: check, effects, interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant{
         _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);

          _revertIfHealthFactorIsBroken(msg.sender);
    }

    // Check if the collateral value > DSC amount, Price feeds, etc.
    /**
     * @notice follow CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // Do we need to check if this break health factor?
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I dont think this would hit... 
    }


    // if we do start nearing undercollateralization, we need someone to liquidate positions

    // $100 ETH backing $50 DSC
    // $20 ETH backing $50 DSC <-- DSC isn't worth $1!!!

    // $75 backing $50 DSC
    // Liquidator takes $75 backing and burns off the $50 DSC
    
    // If someone is almost undercollateralized, we will pay you to liquidate them!

    /**
     * 
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor, Their _healthFactor will be below MIN_HEALTH_FACTOR
     * @param debtToConver The amount of DSC you want to burn to improve the users health factor
     * @notice You can patially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug will be if the protocol were 100% or less collateralized, then we wouldnn't be able to incentivize liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * 
     * follow CEI: check, effects, interactions
     */
    function liquidate(address collateral, address user, uint256 debtToConver) external moreThanZero(debtToConver) nonReentrant {
        // to check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn thier DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100 DSC
        // $100 DSC = ??? ETH?
        // 0.05 ETH
        //  collateral is the total equivalent after deep
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToConver);
        // And give them a 10% bonus
        // so we are giving the liquidator $110 of WETH for $100 DSC
        // We should implenment a feature ti liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        // 0.05 * 0.1 = 0.005, Getting 0.0055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS)/ LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        // Redeem the collateral from the user and transfer it to the msg.sender
        // This will reduce the users collateral value and increase the msg.sender's collateral value
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // Burn the DSC debt from the user
        // This will reduce the user's DSC balance and increase the protocol's DSC balance
        _burnDsc(debtToConver, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();

        }
        _revertIfHealthFactorIsBroken(msg.sender);

    }

    function _getHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns(uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreashold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((collateralAdjustedForThreashold * PRECISION) / totalDscMinted);
    }

    /////////////////////////////////
    // Private & Internal Functions//
    /////////////////////////////////
    
    /**
     * @dev Low-level internal function, do not call unless the function calling is checking for health factor being broken
     * 
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
               s_collateralDeposited[from][tokenCollateralAddress]  -= amountCollateral; 
            //    since we are updating state we are going to emit collateral
            emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
            // _collateralHealthFactorAfter()
            // transfer is when you transfer is to myself; transferFrom is whe you transfer is transfer from myself to somebody else 
            // Transfer the collateral from the contract to the msg.sender
            // This will increase the msg.sender's collateral balance and decrease the contract's collateral balance
            bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
            if (!success) {
                revert DSCEngine__TransferFailed();
            }
           
    }


    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
        
    }
    /**
     * returns how close to liquidation a user is
     * if a user goes below 1, then they can get liquidated
     *
     */

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        // uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // $1000 ETH * 50 = 50,000 / 100 = 500 it mustnt be less than 500
        // $150 ETH * 50 = 7,500 / 100 = 75 it mustnt be less than 75
        // return(collateralValueInUsd / totalDscMinted); //(150/100)
        // 500 * 1e18 / 100
        // return ((collateralAdjustedForThreshold * PRECISION) / totalDscMinted);
        return(_getHealthFactor(totalDscMinted, collateralValueInUsd));
    }

    // 1. Check health factor (do they have enough collateral?)
    // 2. Revert if they dont have
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userhealthFactor = _healthFactor(user);
        if (userhealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userhealthFactor);
        }
    }

    /////////////////////////////////
    // Public & Internal Functions//
    ////////////////////////////////

    

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256){
        // price of ETH using (token address)
        // token is the collateral token
        //  usdAmountInWei is the dept to cover 
        // $/ETH ??
        // $2000 /ETH . $1000 = 0.5 ETH
        AggregatorV3Interface pricefeeds = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = pricefeeds.staleCheckLatestRoundData();
        // multiply the usd amount by the precision (1e18) to make it an integer
        // divide that by the price of the token in USD, 
        // which is multiplied by the additional feed precision (1e10)
        // this is because the price is given in terms of the number of tokens per USD
        // and we want to know how many tokens to give the user
        // so we divide the amount of USD by the price per token
        // which gives us the number of tokens to give the user
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);

    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //  1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8
        console.log(price);
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION; //(1000 * 1e8 * (1e10)) * 1000 * 1e18;
    }

    // function getDscValue()
    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd)  {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user); 
    }

    function getPrecision() external pure returns(uint256) {
        return PRECISION;
    }

    function getHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external pure returns(uint256) {
        return _getHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function calculateHealthFactor(address user) external view returns(uint256) {
        return _healthFactor(user);
    }

    function getLiquidationBonus() external pure returns(uint256){
        return LIQUIDATION_BONUS;
    }

    function getCollateralTokenPriceFeeds(address token) external view returns(address){
        return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns(address[] memory){
        return s_collateralTokens;
    }
    
    function getMinHealthFactor() external pure returns(uint256){
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationThreshold() external pure returns(uint256){
        return LIQUIDATION_THRESHOLD;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256){
        return s_collateralDeposited[user][token];
    }

    function getDsc() external view returns(address){
        return address(i_dsc);
    }

}
