// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { TSwapPoolTest } from "../../test/unit/PoolFactoryTest.t.sol";

///////////////////////////////////////////////////////////////////////////////////
///////////////////// PoC test codes   ////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////////

contract ProofOfCodes is PuppyRaffleTest {
    function test_overTaxingUsersInSwapExactOutput() public {
        // providing liquidity to the pool
        uint256 initialLiquidity = 100e18;

        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);

        pool.deposit({
            wethToDeposit: initialLiquidity,
            minimumLiquidityTokensToMint: 0,
            maximumPoolTokensToDeposit: initialLiquidity,
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        // @audit this function actually returns an incorrect value
        // uint256 priceOfOneWeth = pool.getPriceOfOneWethInPoolTokens();

        address someUser = makeAddr("someUser");
        uint256 userInitialPoolTokenBalance = 11e18;
        poolToken.mint(someUser, 11e18); // now the user has 11 pool tokens

        // user intends to buy 1 weth with pool tokens
        vm.startPrank(someUser);
        poolToken.approve(address(pool), type(uint256).max);
        pool.swapExactOutput(poolToken, weth, 1e18, uint64(block.timestamp));
        vm.stopPrank();

        uint256 userEndingPoolTokenBalance = poolToken.balanceOf(someUser);

        console.log("Initial user balance: ", userInitialPoolTokenBalance);
        // console.log("Price of 1 weth: ", priceOfOneWeth);
        console.log("Ending user balance: ", userEndingPoolTokenBalance);

        // Initial liquidity was 1:1, so user should have paid ~1 pool token
        // However, it spent much more than that. The user started with 11 tokens, and now only has less than 1.
        assert(userEndingPoolTokenBalance < 1 ether);
    }

    /**
     * @notice In scenarios where inputAmount is close to the minOutputAmount, even a small loss of precision can lead
     * to the outputAmount falling below minOutputAmount, triggering the TSwapPool__OutputTooLow error.
     */
    function test_incorrectPriceValueReturnedByGetPriceOfOneWethInPoolTokens() public {
        uint256 precision = 1 ether;

        // we need more liquidity in the pool, so granting additional money for the provider
        weth.mint(liquidityProvider, 800e18);
        poolToken.mint(liquidityProvider, 800e18);

        // providing liquidity to the pool
        uint256 initialLiquidity = 1000e18;

        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);

        pool.deposit({
            wethToDeposit: initialLiquidity,
            minimumLiquidityTokensToMint: 0,
            maximumPoolTokensToDeposit: initialLiquidity,
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        uint256 incorrectPriceOfOneWeth = pool.getPriceOfOneWethInPoolTokens();
        uint256 correctPriceOfOneWeth = (1e18 * precision) / incorrectPriceOfOneWeth;

        console.log("Incorrect price: ", incorrectPriceOfOneWeth); // 987_158_034_397_061_298 = 9.87*10**17
        console.log("Correct price: ", correctPriceOfOneWeth);

        address userSuccess = makeAddr("userSuccess");
        address userFail = makeAddr("userFail");

        // userFail attempts to buy 1 weth with a balance of pool tokens that equals the incorrect price of 1 weth
        poolToken.mint(userFail, incorrectPriceOfOneWeth);
        vm.startPrank(userFail);
        poolToken.approve(address(pool), type(uint256).max);
        // expect a revert (specifically, TSwapPool__OutputTooLow)
        vm.expectRevert();
        // using swapExactOutput() would be more appropriate here, but that one has a huge bug
        pool.swapExactInput({
            inputToken: poolToken,
            inputAmount: incorrectPriceOfOneWeth,
            outputToken: weth,
            minOutputAmount: 99999e13, // due to precision loss, we cant really expect to get 1 full weth (1000e15), we
                // can only approximate
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        // userSuccess attempts to buy 1 weth with a balance of pool tokens that equals the correct price of 1 weth
        poolToken.mint(userSuccess, correctPriceOfOneWeth);
        vm.startPrank(userSuccess);
        poolToken.approve(address(pool), type(uint256).max);
        // using swapExactOutput() would be more appropriate here, but that one has a huge bug
        pool.swapExactInput({
            inputToken: poolToken,
            inputAmount: correctPriceOfOneWeth,
            outputToken: weth,
            minOutputAmount: 99999e13, // due to precision loss, we cant really expect to get 1 full weth (1000e15), we
                // can only approximate
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        assert(weth.balanceOf(userSuccess) > 999e15); // has nearly 1 full weth
        assertEq(poolToken.balanceOf(userSuccess), 0); // spent all his poolToken
    }

    function test_sellPoolTokensCallsTheIncorrectSwapFunction() public {
        // setting up the pool by providing liquidity
        uint256 initialLiquidity = 100e18;

        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), initialLiquidity);
        poolToken.approve(address(pool), initialLiquidity);

        pool.deposit({
            wethToDeposit: initialLiquidity,
            minimumLiquidityTokensToMint: 0,
            maximumPoolTokensToDeposit: initialLiquidity,
            deadline: uint64(block.timestamp)
        });
        vm.stopPrank();

        // setting up the user
        address someUser = makeAddr("someUser");
        uint256 userStartingPoolTokenBalance = 100 ether;
        poolToken.mint(someUser, userStartingPoolTokenBalance);
        vm.prank(someUser);
        poolToken.approve(address(pool), type(uint256).max);

        // user intends to sell 5 pool tokens
        vm.prank(someUser);
        uint256 poolTokensToSell = 5e18;
        // @note that sellPoolTokens() uses swapExactOutput() to perform the swap,
        // which in turn calls getInputAmountBasedOnOutput() to calculate the amount of input tokens to be
        // deducted from the user, and this function miscalculates the fee, so to make things worse,
        // the user becomes subject of overtaxing too
        pool.sellPoolTokens(poolTokensToSell);

        uint256 expectedEndingUserPoolTokenBalance = userStartingPoolTokenBalance - poolTokensToSell;
        uint256 realEndingUserPoolTokenBalance = poolToken.balanceOf(someUser);

        console.log("Expected pool token balance of the user: ", expectedEndingUserPoolTokenBalance);
        console.log("Real pool token balance of the user: ", realEndingUserPoolTokenBalance);

        assert(expectedEndingUserPoolTokenBalance > realEndingUserPoolTokenBalance);
    }

    function test_InvariantBreaks() public {
        // providing liquidity
        vm.startPrank(liquidityProvider);
        weth.approve(address(pool), 100e18);
        poolToken.approve(address(pool), 100e18);
        pool.deposit(100e18, 100e18, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        uint256 outputWeth = 1e17;

        // set up user, than perform 9 swaps
        vm.startPrank(user);
        poolToken.mint(user, 100e18);
        poolToken.approve(address(pool), type(uint256).max);
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));

        // from the invariant test (the handler).
        // We use these here because the interesting thing happens at the 10th swap
        int256 startingY = int256(weth.balanceOf(address(pool)));
        int256 expectedDeltaY = int256(-1) * int256(outputWeth); // this is deltaY

        // and then do a swap for the 10th time
        pool.swapExactOutput(poolToken, weth, outputWeth, uint64(block.timestamp));
        vm.stopPrank();

        // from the invariant test (the handler)
        uint256 endingY = weth.balanceOf(address(pool));
        int256 actualDeltaY = int256(endingY) - int256(startingY); // this could be negative

        assertEq(expectedDeltaY, actualDeltaY);
    }
}
