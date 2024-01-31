// SPDX-Licence-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from "forge-std/Test.sol";
import { Handler } from "./Handler.t.sol";
// for stateful fuzzing
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { PoolFactory } from "../../../src/PoolFactory.sol";
import { TSwapPool } from "../../../src/PoolFactory.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract Invariant is StdInvariant, Test {
    // contracts
    PoolFactory factory;
    TSwapPool pool;
    Handler handler;

    // pool assets
    ERC20Mock weth;
    ERC20Mock poolToken;

    // more assets
    ERC20Mock mockTokenA;
    ERC20Mock mockTokenB;

    // starting pool balances
    int256 public constant STARTING_X = 100e18; // starting pool token balance
    int256 public constant STARTING_Y = 50e18; // starting weth token amount

    function setUp() public {
        weth = new ERC20Mock();
        poolToken = new ERC20Mock();
        mockTokenA = new ERC20Mock();
        mockTokenB = new ERC20Mock();

        factory = new PoolFactory(address(weth));

        // pool is created by the factory
        pool = TSwapPool(factory.createPool(address(poolToken)));

        // create balances to jump-start the pool
        // ------- 1. mint tokens
        poolToken.mint(address(this), uint256(STARTING_X));
        weth.mint(address(this), uint256(STARTING_Y));
        // ------- 2. approve
        poolToken.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        // ------- 3. actually deposit
        // ------- 2nd input arg we can pick if the pool is empty
        // ------- 4th input arg is deadline, we dont really care about it
        pool.deposit(uint256(STARTING_Y), uint256(STARTING_Y), uint256(STARTING_X), uint64(block.timestamp));

        handler = new Handler(pool);
        // specify what contract to do fuzz test on
        targetContract(address(handler));
        // specify targete selectors
        bytes4[] memory selectors = new bytes4[](2); // for vars defined in memory, we need to specify the size at
            // declararion
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.swapPoolTokenForWethBasedOnOutputWeth.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function statefulFuzz_constantProductFormulaStaysTheSame_deltaX() public {
        // the change in the pool size of weth should follow the following formula
        // Δx = ( β/(1/β) ) * x
        // How do we do this? In a handler, we compute the actual delta x and compare it with this formula
        // @note assertEq gives much more informatiove output than assert(==)
        assertEq(handler.actualDeltaX(), handler.expectedDeltaX());
    }

    function statefulFuzz_constantProductFormulaStaysTheSame_deltaY() public {
        assertEq(handler.actualDeltaY(), handler.expectedDeltaY());
    }
}
