# Review with fuzzing

1. Types of fuzz tests (examples in directory "sc-exploits-minimized")
   1. Stateless fuzzing (always getting a new ballon for the next test)
   2. Open stateful fuzzing (rarely makes sense, because there are too many random calls (on random function is rnadom orders with random input))
   3. Stateful fuzzing with handler (fuzzing is done on the handler contract which is a proxy of the original contract, and narrows down the randomization so that there would be meaningful calls)


2. Possible issue: fee on transfer ERC20 tokens: they take a fee when doing a transfer. (There are a lot of this kind.)

3. @note In foundry.toml, add 
```javascript
[fuzz]
seed = '0x1'
```
This way, the fails will be the same between different runs if the code remain unchanged.

4. Suggested design pattern: 
   1. [FREI-PI](https://www.nascent.xyz/idea/youre-writing-require-statements-wrong) Functions-Requires-Effects-Interactions Protocol-Invariant break-prevention
   2. CEII = CEI + pre-and post invariant checks


5. Attack vectors:
   1. @note Weird ERC20s (see [full list](https://github.com/d-xo/weird-erc20))
      1. "fee on transfer" tokens
      2. reentrancy
      3. missing return values (on transer), like BNB, USDC? OMG
      4. upgradeable tokens, e.g. USDC is a proxy, can be updated to be anything!
      5. rebasing token
      6. ...
   Protection:
      1. @note Use `using SafeERC20 for IERC20;` in the code. This does safe transfers and stuff, and protects us from some of the weirdness of ERC20s
   2. Missing slippage protection
   3. Mismatched parameters (decalration vs calls)
   4. Declared but not utilized return params
   5. 


# Review with tools

1. The project has a makefile with `make slither` set up, so run this. In `make slither`, a `slither.config.json` is used, where it is defined what to skip.
2. Aderyn ok
3. @note Use the compiler as a tool. E.g. it notifies us about unused params in the code. In this codebase, the deadline input arguments is not used in the deposit function, so the trx will not revert as expected, severely breaking the intended functionality of the protocol
   


# Best practices

1. Do not use the fuzz test as a PoC, as it it too confusing to read for most. Use the sequence of the output of the fuzz test to recreate the whole thing in a unit test. Replictae the sequnece that the fuzz test gave us.

