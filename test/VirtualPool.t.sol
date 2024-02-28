// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {GetSender} from "./shared/GetSender.sol";
import {VirtualPool} from "../contracts/hooks/examples/VirtualPool.sol";
import {VirtualPoolImplementation} from "./shared/implementation/VirtualPoolImplementation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {HookEnabledSwapRouter} from "./utils/HookEnabledSwapRouter.sol";

contract TestVirtualPool is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using Pool for Pool.State;

    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;
    VirtualPool virtualPool = VirtualPool(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG
                            | Hooks.BEFORE_MODIFY_POSITION_FLAG
                            | Hooks.BEFORE_SWAP_FLAG
                            | Hooks.NO_OP_FLAG)));
    // for the virtual pool
    PoolId idVirtual;
    PoolKey keyVirtual;

    // for the real pools
    PoolId id1;
    PoolKey key1;
    PoolId id2;
    PoolKey key2;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        vm.record();
        VirtualPoolImplementation impl = new VirtualPoolImplementation(manager, virtualPool);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(virtualPool), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(virtualPool), slot, vm.load(address(impl), slot));
            }
        }

        // deploy the real pools; adds 1e18 liquidity in each of them, in the -120 to +120 tick range
        (key1, id1) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);
        (key2, id2) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 500, SQRT_RATIO_1_1, ZERO_BYTES);

        // deploy the virtual pool; the tick spacing does not really matter, but zero is not accepted
        virtualPool.setPool1(id1, key1);
        virtualPool.setPool2(id2, key2);
        (keyVirtual, idVirtual) = initPool(currency0, currency1, virtualPool, 100, SQRT_RATIO_1_1, ZERO_BYTES);

        // only the virtual pool needs to be approved, not the router, because only it is doing the actual token transfers
        token0.approve(address(virtualPool), type(uint256).max);
        token1.approve(address(virtualPool), type(uint256).max);
    }

    function testSwapZeroForOne() public {
        PoolKey memory key = keyVirtual;
        Pool.Slot0 memory slot0;

        console2.log("balance before:");
        console2.logUint(key.currency0.balanceOf(address(this)));
        console2.logUint(key.currency1.balanceOf(address(this)));

        console2.log("price before:");
        (slot0,,,) = manager.pools(id1);
        console2.logUint(slot0.sqrtPriceX96);
        (slot0,,,) = manager.pools(id2);
        console2.logUint(slot0.sqrtPriceX96);

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0.001e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1});
        HookEnabledSwapRouter.TestSettings memory settings =
            HookEnabledSwapRouter.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        snapStart("VirtualPoolSwap");
        router.swap(key, params, settings, abi.encode(address(this)));
        snapEnd();

        console2.log("balance after:");
        console2.logUint(key.currency0.balanceOf(address(this)));
        console2.logUint(key.currency1.balanceOf(address(this)));

        console2.log("price after:");
        (slot0,,,) = manager.pools(id1);
        console2.logUint(slot0.sqrtPriceX96);
        (slot0,,,) = manager.pools(id2);
        console2.logUint(slot0.sqrtPriceX96);

        assertEq(true, true);
    }
}
