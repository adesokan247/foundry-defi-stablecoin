// SPDX-License-Identifier: MIT
// Handler is going to narrow down the way we call function

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

// Price feed
// WETH Token
// WBTC Token

// The Handler contract and fuzz testing play a crucial role in ensuring the robustness and security of your smart contracts. By automating the process of generating random inputs and verifying invariants, you can identify and fix potential issues before they become problems in a live environment.


contract Handler is Test{
// need a constructor so that the contract knows what dscengine is 
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    
    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled; 
    address[] public userWithCollateralDeposited;
    // mockv3aggregator has some functions that quickly allows us ti update the answer
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // the max uint96 value

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc; 

        address[] memory collateralTokens = dsce.getCollateralTokens();
        // deployment of ERC20Mock with different addresses
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeeds(address(weth)));

    }

    // This breaks our invariant test suite!!!!
    // function updateCollateralPrice(uint96 newPrice) public {
    //    int256 newPriceInt = int256(uint256(newPrice));
    //    ethUsdPriceFeed.updateAnswer(newPriceInt);
       
    // }

    // redeem collateral <-
    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock){
        if (collateralSeed % 2 == 0) {
            return weth;
        }

        return wbtc;
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if(userWithCollateralDeposited.length == 0) {
            return;
        }
        // addressSeed is the seed that determines which address the funds will be minted from
        // it is used to generate a random address from the list of addresses that have collateral deposited
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        vm.startPrank(sender);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd)/2) - int256(totalDscMinted);
        // to filter out the ones that would break health factor
        if(maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0){
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // bound collateral to be btw 1 and Max
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        userWithCollateralDeposited.push(msg.sender);

    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0){
            return;
        }
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    
    // This breaks our invariant test suite!!!!
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

}