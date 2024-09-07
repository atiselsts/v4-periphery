// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "../../BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

contract VirtualPool is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    bytes internal constant ZERO_BYTES = bytes("");

    PoolId public pool1;
    PoolId public pool2;
    PoolKey public key1;
    PoolKey public key2;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function setPool1(PoolId poolId, PoolKey calldata key) external {
        pool1 = poolId;
        key1 = key;
    }

    function setPool2(PoolId poolId, PoolKey calldata key) external {
        pool2 = poolId;
        key2 = key;
    }

    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        require(PoolId.unwrap(pool1) != bytes32(""), "pool1 is not set");
        require(PoolId.unwrap(pool2) != bytes32(""), "pool2 is not set");

        return VirtualPool.beforeInitialize.selector;
    }

    function beforeModifyPosition(address, PoolKey calldata, IPoolManager.ModifyPositionParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        require(false, "this hook cannot have its own liquidity");
    }

    function beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        IPoolManager.SwapParams memory newParams;

        address payer = abi.decode(hookData, (address));

        // first, swap half (rounding down) in the key1 pool
        newParams.zeroForOne = params.zeroForOne;
        newParams.amountSpecified = params.amountSpecified / 2;
        newParams.sqrtPriceLimitX96 = params.sqrtPriceLimitX96;

        BalanceDelta delta;
        delta = abi.decode(
            poolManager.lock(address(this), abi.encodeCall(this.lockAcquiredSwap, (payer, key1, newParams))),
            (BalanceDelta)
        );

        // then, swap the remainder in the key2 pool
        newParams.amountSpecified = params.amountSpecified - newParams.amountSpecified;
        delta = abi.decode(
            poolManager.lock(address(this), abi.encodeCall(this.lockAcquiredSwap, (payer, key2, newParams))),
            (BalanceDelta)
        );

        // do not run the normal swap algorithm
        return Hooks.NO_OP_SELECTOR;
    }

    function _take(Currency currency, address recipient, int128 amount, bool withdrawTokens) internal {
        assert(amount < 0);
        if (withdrawTokens) {
            poolManager.take(currency, recipient, uint128(-amount));
        } else {
            poolManager.mint(currency, recipient, uint128(-amount));
        }
    }

    function _settle(Currency currency, address payer, int128 amount, bool settleUsingTransfer) internal {
        assert(amount > 0);
        if (settleUsingTransfer) {
            if (currency.isNative()) {
                poolManager.settle{value: uint128(amount)}(currency);
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), uint128(amount));
                poolManager.settle(currency);
            }
        } else {
            poolManager.burn(currency, uint128(amount));
        }
    }

    function lockAcquiredSwap(address payer, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        selfOnly
        returns (bytes memory)
    {
        BalanceDelta delta = poolManager.swap(key, params, ZERO_BYTES);

        if (params.zeroForOne) {
            _settle(key.currency0, payer, delta.amount0(), true);
            if (delta.amount1() < 0) {
                _take(key.currency1, payer, delta.amount1(), true);
            }
        } else {
            _settle(key.currency1, payer, delta.amount1(), true);
            if (delta.amount0() < 0) {
                _take(key.currency0, payer, delta.amount0(), true);
            }
        }

        return abi.encode(delta);
    }

    function getHooksCalls() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            noOp: true,
            accessLock: false
        });
    }
}
