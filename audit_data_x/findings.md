## High

### [H-1] Incorrect fee calculation in `TSwapPool::getInputAmountBasedOnOutput` causes protocol to overtax users with a 90.3% fee

**Description:** The `getInputAmountBasedOnOutput` function is intended to calculate the amount of tokens the users should deposit given the amount of output tokens. However, the function currently miscalculates the resulting amount. When calculating the fee, it scales the amount by 10_000 instead of 1_000, resulting in a 90.3% fee.

**Impact:** Protocol takes more fees than expected by the users.

**Proof of Concept:** Consider the following scenario:

1. The user calls `TSwapPool::swapExactOutput` to buy a predefined amount of output tokens in exchange for an undefined amount of input tokens.
2. `TSwapPool::swapExactOutput` calls the `getInputAmountBasedOnOutput` function that is supposed to calculate the amount of input tokens required to result in the predefined amount of output tokens. However, the fee calculation in this function in incorrect.
3. The user gets overtaxed with a 90.4% fee.

**Proof of Code:**

<details>
<summary>Code</summary>

```javascript

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
```
</details>


**Recommended Mitigation:** 

```diff
    function getInputAmountBasedOnOutput(
        uint256 outputAmount,
        uint256 inputReserves,
        uint256 outputReserves
    )
        public
        pure
        revertIfZero(outputAmount)
        revertIfZero(outputReserves)
        returns (uint256 inputAmount)
    {
-        return ((inputReserves * outputAmount) * 10_000) / ((outputReserves - outputAmount) * 997);
+        return ((inputReserves * outputAmount) * 1_000) / ((outputReserves - outputAmount) * 997);

    }
```



### [H-2] Lack of slippage protection in `TswapPool::swapExactOutput` casues users to potentially receive way fewer tokens

**Description:** The funxtion `swapExactOutput` does not include any kind of slippage protection. This function is similar to what is done in `TSwapPool::swapExactInput`, where the function specifies the `minOutputAmount`. Similarly, `swapExactOutput` should specify a `maxInputAmount`.

**Impact:** If the market conditions change before the transaction process, the user could get a much worse swap then expected.

**Proof of Concept:**

1. The price of WETH is 1_000 USDC.
2. User calls `swapExactOutput`, looking for 1 WETH with the following parameters:
   - inputToken: USDC
   - outputToken: WETH
   - outputAmount: 1
   - deadline: whatever
3. The function does not allow a `maxInputAmount`.
4. As the transaction is pending in the mempool, the market changes, and the price movement is huge: 1 WETH now costs 10_000 USDC, 10x more than the user expected!
5. The transaction completes, but the user got charged 10_000 USDC for 1 WETH.

**Recommended Mitigation:** Include a `maxInputAmount` input parameter in the function declaration, so that the user could specify the maximum amount of tokens he would like to spend and, hence, could predict their spending when using this function of the protocol.

```diff
    function swapExactOutput(
        IERC20 inputToken,
+       uint256 maxInputAmount,
        IERC20 outputToken,
        uint256 outputAmount,
        uint64 deadline
    )
        public
        revertIfZero(outputAmount)
        revertIfDeadlinePassed(deadline)
        returns (uint256 inputAmount)
    {
        
        uint256 inputReserves = inputToken.balanceOf(address(this));
        uint256 outputReserves = outputToken.balanceOf(address(this));

        inputAmount = getInputAmountBasedOnOutput(outputAmount, inputReserves, outputReserves);

+       if(inputAmount > maxInputAmount){
+           revert();
+       }

        _swap(inputToken, inputAmount, outputToken, outputAmount);
    }
```


### [H-3] `TSwapPool::sellPoolTokens` mistakenly calls the incorrect swap function, causing users to receive the incorrect amount of tokens

**Description:** The `sellPoolTokens` function is intended to allow users to easily sell pool tokens and receive WETH in exchange. In the `poolTokenAmount` parameter, users indicate how many pool token they intend to sell. However, the function mistakenly calls `swapExactOutput` instead of `swapExactInput` to perform the swap, and therein assignes the value of `poolTokenAmount` to function input argument `outputAmount`, effectively mixing up the input and output tokens / amounts. 

**Impact:** Users will swap the incorrects amount of tokens, which severely discrupts the functionality of the protocol.

**Proof of Concept:** Consider the following scenario:

1. A user has 100 pool tokens, and wants to sell 5 by calling the `sellPoolTokens` function.
2. Instead of the `swapExactInput` function, `sellPoolTokens`  calls `swapExactOutput`.
3. In `swapExactOutput`, `poolTokenAmount` is used as `outputAmount` while it is really the input amount.
4. As a result, user will swap more output tokens than originally intended.

Apart from this, the user will be overtaxed due to a bug in `getInputAmountBasedOnOutput()` called by `swapExactOutput`.

**Proof of Code:** Add this piece of code `TSwapPool.t.sol`:

<details>
<summary>Code</summary>

```javascript
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
```

</details>



**Recommended Mitigation:** Change the implementation to use `swapExactInput` instead of the `swapExactOutput` function. Note that this would require the `sellPoolTokens` function to accept an additional parameter (i.e. `minOutputAmount` to be passed to `swapExactInput`).

```diff

-    function sellPoolTokens(uint256 poolTokenAmount) external returns (uint256 wethAmount) {
+    function sellPoolTokens(uint256 poolTokenAmount, uint256 minWethToReceive) external returns (uint256 wethAmount) {

-        return swapExactOutput(i_poolToken, i_wethToken, poolTokenAmount, uint64(block.timestamp));
+        return swapExactInput(i_poolToken, i_wethToken, poolTokenAmount, minWethToReceive, uint64(block.timestamp));

    }
```

Additionally, it might be wise to add a deadline to the function, as currently there is no deadline. MEV later.


### [H-4] In `TswapPool::_swap` the extra tokens given to users after every `swapCount` breaks the protocol invariant of `x * y = k`

**Description:** The protocol follows a strict invariant of `x * y = k`, where 
- `x`: The balance of the pool token in the pool
- `y`: The balance of WETH in the pool
- `k`: The constant product of the 2 balances

This means that whenever the balances change in the protocol, the ratio between the two amounts should remain constant, hence the `k`. However, this is broken due to the extra incentive (a full extra token after every 10 swaps) in the `_swap` function, meaning that over time the protocol funds would be drained. 

The following block of code is responsible for the issue.

```javascript
        swap_count++;
        if (swap_count >= SWAP_COUNT_MAX) {
            swap_count = 0;
            outputToken.safeTransfer(msg.sender, 1_000_000_000_000_000_000);
        }
```


**Impact:** A user could maliciously drain the protocol of funds by doing a lot of swaps and collecting the extra incentive (a full extra token after every 10 swaps) given out by the protocol. 

More simply put, the core invariant of the protocol is broken!

**Proof of Concept:**
1. A user swaps 10 times and collects the extra incentive of 1 token (`1_000_000_000_000_000_000`)
2. The usercontinues to swap until all the protocol funds are drained.

**Proof of Code:**

<details>
<summary>Code</summary>

```javascript
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
```
</details>


**Recommended Mitigation:** Remove the extra incentive mechanism. If you want to keep this nonetheless, you should account for the change in the `x * y = k` invariant. Alternatively, you could set aside tokens the same way you did with fees.

```diff
-        swap_count++;
-        if (swap_count >= SWAP_COUNT_MAX) {
-            swap_count = 0;
-            outputToken.safeTransfer(msg.sender, 1_000_000_000_000_000_000);
-        }
```



### [H-5] Rebase, fee-on-transfer, and ERC777 tokens break protocol invariant

**Description:** Weird ERC20 tokens with uncommon / malicious implementations can endanger the whole protocol. Examples include rebase, fee-on-transfer, and ERC777 tokens.

**Impact:** 

**Proof of Concept:**

**Recommended Mitigation:** 



## Medium

### [M-1] `TSwapPool::deposit` is missing deadline check, causing transactions to complete even after the deadline passed

**Description:** The `deposit` function accepts a `deadline` as an input the parameter which, according to the documentation, "the deadline for the transaction to be completed by". However, this parameter is never actually used. As a consequence, operations that add liquidty to the pool might be executed at unexpected times, in market conditions when the deposit rate is unfavorable.

This also makes this part susceptible to MEV attacks.

**Impact:** Transactions can be sent when market conditions are unfavorable, even when the deadline is set.

**Proof of Concept:** The `deadline` parameter is unused (this is highlighted by the compiler too).

**Recommended Mitigation:** Make the following change to the function:

```diff
   function deposit(
        uint256 wethToDeposit,
        uint256 minimumLiquidityTokensToMint,
        uint256 maximumPoolTokensToDeposit,
        uint64 deadline
    )
        external
+       revertIfDeadlinePassed(deadline)
        revertIfZero(wethToDeposit)
        returns (uint256 liquidityTokensToMint)
    {...}

```


### [M-2] `TSwapPool::getPriceOfOneWethInPoolTokens()` and `TSwapPool::getPriceOfOnePoolTokenInWeth()` return incorrect price values

**Description:** `getPriceOfOneWethInPoolTokens` is supposed to return the price of 1 WETH in terms of pool tokens, and `TSwapPool::getPriceOfOnePoolTokenInWeth` is supposed to return the price of 1 pool token in terms of WETH. However, the return values are incorrect. Both functions return the amount of output tokens after fees, which is not the same as the price of 1 output token in input tokens. (Consider this: as compared to a fee-less protocol, if there are fees, the amount of output tokens should be lower, while the price should be not lower but higher.) 

**Impact:** User will think that the WETH / pool token is cheaper that it actually is, and they might make their trading decisions based on this incorrect price information. E.g. they might think the price of their token is falling, might panic and sell their tokens to avoid further losses by calling `sellPoolTokens()`.

**Proof of Concept:** Consider the following scenario:

1. A user has 1 WETH, and wants to swap it for pool tokens.
2. The user calls `getPriceOfOneWethInPoolTokens` and sees an incorrect price that is the inverse of the actual price.
3. User finds the price appealing and swaps his WETH.
4. User ends up with a lot less pool tokens than he expected.

**Proof of Code:** Insert this piece of code to `TSwapPool.t.sol` (note the it demonstrates a different scenario than the one written under "Proof of Concept"):

<details>
<summary>Code</summary>

```javascript
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
```

</details>


**Recommended Mitigation:** 

```diff
    function getPriceOfOneWethInPoolTokens() external view returns (uint256) {
-        return getOutputAmountBasedOnInput(
-            1e18, i_wethToken.balanceOf(address(this)), i_poolToken.balanceOf(address(this))
-        );
+       uint256 precision = 1e18;
+       uint256 amountOfPoolTokensReceivedForOneWeth = getOutputAmountBasedOnInput(
+            1e18, i_wethToken.balanceOf(address(this)), i_poolToken.balanceOf(address(this)));
+            
+        uint256 priceOfOneWethInPoolTokens = (1e18 * precision) / amountOfPoolTokensReceivedForOneWeth;
+
+     return priceOfOneWethInPoolTokens;
    }

    function getPriceOfOnePoolTokenInWeth() external view returns (uint256) {
-        return getOutputAmountBasedOnInput(
-            1e18, i_poolToken.balanceOf(address(this)), i_wethToken.balanceOf(address(this))
-        );
+       uint256 precision = 1e18;
+       uint256 amountOfWethReceivedForOnePoolToken = getOutputAmountBasedOnInput(
+            1e18, i_poolToken.balanceOf(address(this)), i_wethToken.balanceOf(address(this)));
+            
+        uint256 priceOfOnePoolTokenInWeth = (1e18 * precision) / amountOfWethReceivedForOnePoolToke;
+
+     return priceOfOnePoolTokenInWeth;
    }
```

## Low

### [L-1] `TSwapPool::LiquidityAdded` event has parameters out of order, causing event to emit incorrect information

**Description:** When the `LiquidtyAdded` event is emitted in the `TSwapPool::_addLiquidityMintAndTransfer`, it logs values in the incorrect order. The `poolTokensToDeposit` value should go to the 3rd parameter position, whereas the `wethToDeposit` should go to 2nd.

**Impact:** The emit emission is incorrect, causing off-chain functions potentially malfunctioning.

**Recommended Mitigation:** 

```diff
-        emit LiquidityAdded(msg.sender, poolTokensToDeposit, wethToDeposit);
+        emit LiquidityAdded(msg.sender, wethToDeposit, poolTokensToDeposit);
```


### [L-2] In the function declaration of `TSwapPool::swapExactInput`, a return value is defined but never assigned a value, resulting in a default but incorrect return value

**Description:** The `swapExactInput` function is expected to return the actual amount of tokens bought by the user. However, while it declares the named return value `output`, it never assigns a value to it, nor uses an explicit return statement.

**Impact:** The return value will always be 0, giving an incorrect information to the user.

**Proof of Concept:**

**Recommended Mitigation:** 

```diff
    function swapExactInput(
        IERC20 inputToken, // e input token to swap, e.g. sell DAI
        uint256 inputAmount, // e amount of DAI to sell
        IERC20 outputToken, // e token to buy, e.g. weth
        uint256 minOutputAmount, // mint weth to get
        uint64 deadline // deadline for the swap execution
    )
        public
        revertIfZero(inputAmount)
        revertIfDeadlinePassed(deadline)
        returns (
-            uint256 output
+            uint256 outputAmount

        )
    {
        uint256 inputReserves = inputToken.balanceOf(address(this));
        uint256 outputReserves = outputToken.balanceOf(address(this));

-        uint256 outputAmount = getOutputAmountBasedOnInput(inputAmount, inputReserves, outputReserves);
+        outputAmount = getOutputAmountBasedOnInput(inputAmount, inputReserves, outputReserves);



        if (outputAmount < minOutputAmount) {
            revert TSwapPool__OutputTooLow(outputAmount, minOutputAmount);


        }
        _swap(inputToken, inputAmount, outputToken, outputAmount);

+       return outputAmount;

    }

```



## Informationals

### [I-1] Custom error `PoolFactory::PoolFactory__PoolDoesNotExist(address tokenAddress)` is not used

**Description:** Custom error `PoolFactory::PoolFactory__PoolDoesNotExist(address tokenAddress)` is not used anywhere in the code, and should be removed.

**Recommended Mitigation:**
```diff
-       error PoolFactory__PoolDoesNotExist(address tokenAddress);
```

### [I-2] Missing zero address checks in both the `PoolFactory.sol` and `TSwapPool.sol` contracts

**Description:** Both `PoolFactory.sol` and `TSwapPool.sol` contain functions which do not check if the address provided as an input argument is the zero address (address(0)). According to the best practice, zero address checks should be performed. Instantes:

- `contructor(address wethToken)` in `PoolFactory.sol`
- `constructor(address poolToken, address wethToken, string memory liquidityTokenName, string memory liquidityTokenSymbol)` in `TSwapPool.sol`

**Recommended Mitigation:** Add checks to these functions, preferably with custom error. Example for the first instance

```diff
+       error PoolFactory__IsZeroAddress();

        constructor(address wethToken) {
+       if(wethToken == address(0)){
+          revert PoolFactory__IsZeroAddress(); 
+       }
        i_wethToken = wethToken;
    }
```

### [I-3] Use `.symbol` instead of `.name` when assigning a value to `liquidityTokenSymbol` In `PoolFactory::createPool()`, 

**Description:** To be more in line with the name of the variable (and intended use thereof), use `.symbol` instead of `.name` when assigning a value to `liquidityTokenSymbol` In `PoolFactory::createPool()`

**Recommended Mitigation:** 

```diff
-         string memory liquidityTokenSymbol = string.concat("ts", IERC20(tokenAddress).name());
+         string memory liquidityTokenSymbol = string.concat("ts", IERC20(tokenAddress).symbol());

```


### [I-4] Consider indexing up to 3 input parameters in events for facilitating better searching and filtering

**Description:** Indexing is a feature used with events. When you declare an event, you can mark up to three parameters as indexed. This means these parameters are treated in a special way by the Ethereum Virtual Machine (EVM). Indexing facilitates searching and filtering: when parameters in an event are indexed, they are stored in a way that allows you to search and filter for these events using these parameters. Indexing is commonly used in scenarios like tracking transfers of tokens, logging changes in ownership, or recording key actions taken in a contract.
At the same time, however, keep in mind that you can index only up to 3 parameters, and that indexing increases the gas cost of event emission.

Found in:

- src/PoolFactory.sol [Line: 35](src/PoolFactory.sol#L35)
- src/TSwapPool.sol [Line: 43](src/TSwapPool.sol#L43)
- src/TSwapPool.sol [Line: 44](src/TSwapPool.sol#L44)
- src/TSwapPool.sol [Line: 45](src/TSwapPool.sol#L45)

**Recommended Mitigation:** 

```diff
-     event Swap(address indexed swapper, IERC20 tokenIn, uint256 amountTokenIn, IERC20 tokenOut, uint256 amountTokenOut);
+     event Swap(address indexed swapper, indexed IERC20 tokenIn, indexed uint256 amountTokenIn, IERC20 tokenOut, uint256 amountTokenOut);

```

### [I-5] No need to emit public constant `MINIMUM_WETH_LIQUIDITY` in custom error `TSwapPool::TSwapPool__WethDepositAmountTooLow`

**Description:** The value of public constant `MINIMUM_WETH_LIQUIDITY` can be queried by anybody any time on the blockchain and, hence, it is unneccesary to emit it in custom error `TSwapPool::TSwapPool__WethDepositAmountTooLow`.

**Recommended Mitigation:** 

```diff
-  error TSwapPool__WethDepositAmountTooLow(uint256 minimumWethDeposit, uint256 wethToDeposit);
+  error TSwapPool__WethDepositAmountTooLow();
```


### [I-6] Explanatory documentation in `TSwapPool::deposit` is partially incorrect

**Description:** The following part of the `TSwapPool:deposit` documentation is incorrect:

"           // So we can do some elementary math now to figure out poolTokensToDeposit...
            // (wethReserves + wethToDeposit) / poolTokensToDeposit = wethReserves
            // (wethReserves + wethToDeposit)  = wethReserves * poolTokensToDeposit
            // (wethReserves + wethToDeposit) / wethReserves  =  poolTokensToDeposit "

Note that the parts above these are correct but not this part. The transition to (wethReserves+wethToDeposit)/poolTokensToDeposit=wethReserves is where the confusio arises. This equation does not maintain the constant product formula. It instead suggests that the ratio of the total WETH (after deposit) to the pool tokens to deposit equals the original WETH reserves, which is not consistent with maintaining the constant product.


### [I-7] CEI is not followed in `TSwapPool::deposit`

**Description:** CEI (Checks-Effects-Interaction), the best-practice design pattern used for avoding reentrency attacks, is not followed in `TSwapPool::deposit`.

<details>
<summary> Code </summary>

```javascript
    function deposit(
        uint256 wethToDeposit,
        uint256 minimumLiquidityTokensToMint,
        uint256 maximumPoolTokensToDeposit,
        uint64 deadline
    )
        external
        revertIfZero(wethToDeposit)
        returns (uint256 liquidityTokensToMint)
    {
        if (wethToDeposit < MINIMUM_WETH_LIQUIDITY) {
            // @audit-info no need to emit MINIMUM_WETH_LIQUIDITY, as it is a public constant, can be checked any time
            revert TSwapPool__WethDepositAmountTooLow(MINIMUM_WETH_LIQUIDITY, wethToDeposit);
        }
        if (totalLiquidityTokenSupply() > 0) {
            uint256 wethReserves = i_wethToken.balanceOf(address(this));
            // @audit gas. This is not used, dont need this line. (Probably you first wanted a manual calculation, but
            // ...ended up using getPoolTokensToDepositBasedOnWeth())
            uint256 poolTokenReserves = i_poolToken.balanceOf(address(this));
            // Our invariant says weth, poolTokens, and liquidity tokens must always have the same ratio after the
            // initial deposit
            // poolTokens / constant(k) = weth
            // weth / constant(k) = liquidityTokens
            // aka...
            // weth / poolTokens = constant(k)
            // To make sure this holds, we can make sure the new balance will match the old balance
            // (wethReserves + wethToDeposit) / (poolTokenReserves + poolTokensToDeposit) = constant(k)
            // (wethReserves + wethToDeposit) / (poolTokenReserves + poolTokensToDeposit) =
            // (wethReserves / poolTokenReserves)

            // So we can do some elementary math now to figure out poolTokensToDeposit...
            // (wethReserves + wethToDeposit) / poolTokensToDeposit = wethReserves
            // (wethReserves + wethToDeposit)  = wethReserves * poolTokensToDeposit
            // (wethReserves + wethToDeposit) / wethReserves  =  poolTokensToDeposit
            uint256 poolTokensToDeposit = getPoolTokensToDepositBasedOnWeth(wethToDeposit);
            // e if we calculate too many poolTokens to deposit, revert, good
            if (maximumPoolTokensToDeposit < poolTokensToDeposit) {
                revert TSwapPool__MaxPoolTokenDepositTooHigh(maximumPoolTokensToDeposit, poolTokensToDeposit);
            }

            // We do the same thing for liquidity tokens. Similar math.
            liquidityTokensToMint = (wethToDeposit * totalLiquidityTokenSupply()) / wethReserves;
            if (liquidityTokensToMint < minimumLiquidityTokensToMint) {
                revert TSwapPool__MinLiquidityTokensToMintTooLow(minimumLiquidityTokensToMint, liquidityTokensToMint);
            }
            _addLiquidityMintAndTransfer(wethToDeposit, poolTokensToDeposit, liquidityTokensToMint);
        } else {
            // This will be the "initial" funding of the protocol. We are starting from blank here!
            // We just have them send the tokens in, and we mint liquidity tokens based on the weth
            _addLiquidityMintAndTransfer(wethToDeposit, maximumPoolTokensToDeposit, wethToDeposit);
            // e not a state var, but nonetheless
            // @audit-info move this line before the external calls to follow CEI
    @>        liquidityTokensToMint = wethToDeposit;
        }
    }

```
</details>

**Impact:** Since `liquidityTokensToMint` is not a state variable, it is not that much of an issue that it is being updated after the interactions (making calls to external functions). Still, as a best practice, it is better to you CEI here as well.

**Recommended Mitigation:** 

```diff
+            liquidityTokensToMint = wethToDeposit;
            _addLiquidityMintAndTransfer(wethToDeposit, maximumPoolTokensToDeposit, wethToDeposit);
-            liquidityTokensToMint = wethToDeposit;
```


### [I-8] Natspec in `TSwapPool::_addLiquidityMintAndTransfer` is incorrect, refers to non-existent function

**Description:** The natspec in `TSwapPool::_addLiquidityMintAndTransfer` incorrectly refers to a non-existent function `addLiquidity`. There is no such function - instead, the function used to add liquidity to a pool is `deposit`.


### [I-9] Use of "magic" numbers (numbers without descriptors) is discouraged

It can be confusing to see number literals in a codebase and it is much more readable if the numbers are given a name.
Moreover, using number literals can easily lead to errors, see one of the high vulnerabilities in the report.

Examples:

In `TSwapPool::getAmountBasedOnInput`:

```javascript
        uint256 inputAmountMinusFee = inputAmount * 997;
        uint256 numerator = inputAmountMinusFee * outputReserves;
        uint256 denominator = (inputReserves * 1000) + inputAmountMinusFee;
```

and in `TSwapPool::getAmountBasedOnOutput`:


```javascript
        return ((inputReserves * outputAmount) * 10000) / ((outputReserves - outputAmount) * 997);

```

Instead, you could use:

```javascript
uint256 public constant AMOUNT_PRECISION = 1000;
uint256 public constant RETURNED_AMOUNT = 997;
```

### [I-10] `TSwapPool:swapExactInput` lacks natspec

**Description:** No documentation, explanation is provided for key function `swapExactInput`.


### [I-11] `TSwapPool:swapExactInput` can be marked as an external function

**Description:** `swapExactInput` is declared as a public function. However, it is not used internally and, hence, can be declared as external instead.


## Gas

### [G-1] The `wethReserves` local variable is not used in `TSwapPool::deposit` and, as such, should be removed to save gas.

**Description:** 

**Recommended Mitigation:** 

```diff
-             uint256 wethReserves = i_wethToken.balanceOf(address(this));

```