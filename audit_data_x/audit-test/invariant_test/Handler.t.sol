// SPDX-Licence-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console2 } from "../../../lib/forge-std/src/Test.sol";
import { TSwapPool } from "../../../src/TSwapPool.sol";
import { ERC20Mock } from
    "/home/orgovaan/security/5-t-swap-audit/lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract Handler is Test {
    //Invariant invariant;
    //PoolFactory factory;
    TSwapPool pool;
    ERC20Mock weth;
    ERC20Mock poolToken;

    // ghost variables: dont exist in the contract but they do in our handler
    int256 startingY;
    int256 startingX;

    // change in token balances
    int256 public expectedDeltaY;
    int256 public expectedDeltaX;
    int256 public actualDeltaX;
    int256 public actualDeltaY;

    address liquidityProvider = makeAddr("lp");
    address swapper = makeAddr("swapper");

    constructor(TSwapPool _pool) {
        // @note everything is deployed in Invariant.t.sol
        pool = _pool;
        weth = ERC20Mock(pool.getWeth());
        poolToken = ERC20Mock(pool.getPoolToken());
    }

    // what functions do we want to call? deposit and swapExactOutput for sure!

    function deposit(uint256 wethAmount) public {
        // making sure it is a reasonable amount, avoid weird overflow issues
        uint256 minWeth = pool.getMinimumWethDepositAmount(); // this is a requirement from the pool
        wethAmount = bound(wethAmount, minWeth, type(uint64).max); // max is 18.44.. ETH

        startingX = int256(poolToken.balanceOf(address(pool)));
        startingY = int256(weth.balanceOf(address(pool)));

        expectedDeltaY = int256(wethAmount); // this is deltaY
        // from man. review we know to use this function call
        expectedDeltaX = int256(pool.getPoolTokensToDepositBasedOnWeth(wethAmount));

        // deposit flow
        vm.startPrank(liquidityProvider);
        // ---- 1. ensure the liquidity provider has a balance of these tokens so that he can deposit
        weth.mint(liquidityProvider, wethAmount);
        poolToken.mint(liquidityProvider, uint256(expectedDeltaX));
        // ---- 2. approvals
        weth.approve(address(pool), type(uint256).max); // maxing out the approval amount
        poolToken.approve(address(pool), type(uint256).max); // maxing out the approval amount
        // ---- 3. deposit. @note the 2nd arguments does not really matter to us
        pool.deposit(wethAmount, 0, uint256(expectedDeltaX), uint64(block.timestamp));
        vm.stopPrank();

        uint256 endingX = poolToken.balanceOf(address(pool));
        uint256 endingY = weth.balanceOf(address(pool));

        actualDeltaY = int256(endingY) - int256(startingY); // this could be negative
        actualDeltaX = int256(endingX) - int256(startingX); // this could be negative
    }

    function swapPoolTokenForWethBasedOnOutputWeth(uint256 outputWeth) public {
        outputWeth = bound(outputWeth, 1, weth.balanceOf(address(pool))); // this max value can be tricky, originally we
            // had type(uint64).max here
        // we dont need to change the min value like Patrikc did, right?? https://youtu.be/pUWmJ86X_do?t=42863
        if (outputWeth >= weth.balanceOf(address(pool))) {
            // we do not want to swap the total balance of the pool
            return;
        }

        // ∆x = (β/(1-β)) * x
        // 2nd and 3rd arguments are the inputReserves and outputReserves
        // so this is ∆x. We could have written our own function to calculate this, but we had this ready...
        // and we had a bit of a manual review to check it was correct, and it is, see the TSwapPool.sol file
        uint256 poolTokenAmount = pool.getInputAmountBasedOnOutput(
            outputWeth, poolToken.balanceOf(address(pool)), weth.balanceOf(address(pool))
        );
        if (poolTokenAmount > type(uint64).max) {
            // if the value is too high, just return
            return;
        }

        // update the starting deltas, mainly copying 4 lines of code from deposit(), with little modifications
        startingX = int256(poolToken.balanceOf(address(pool)));
        startingY = int256(weth.balanceOf(address(pool)));

        expectedDeltaY = int256(-1) * int256(outputWeth); // this is deltaY @note the difference: the pool is loosing...
            // ...weth here, not gaining, unlike what happened during deposit
        // from man. review we know to use this function call
        expectedDeltaX = int256(poolTokenAmount);

        // being very specific when giving poolToken to swapper
        if (poolToken.balanceOf(swapper) < poolTokenAmount) {
            poolToken.mint(swapper, poolTokenAmount - poolToken.balanceOf(swapper) + 1);
        }

        vm.startPrank(swapper);
        // poolToken.mint(swapper, poolTokenAmount); // done above, with more specificity
        poolToken.approve(address(pool), type(uint256).max);
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        vm.stopPrank();

        // update the ending deltas, mainly copying again

        uint256 endingX = poolToken.balanceOf(address(pool));
        uint256 endingY = weth.balanceOf(address(pool));

        actualDeltaY = int256(endingY) - int256(startingY); // this could be negative
        actualDeltaX = int256(endingX) - int256(startingX); // this could be negative
    }
}
