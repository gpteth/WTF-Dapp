// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;
import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

// 优化溢出和下溢 安全的数学操作
import './libraries/LowGasSafeMath.sol';

import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

contract Pool is IPool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    // tick 元数据管理的库
    using Tick for mapping(int24 => Tick.Info);
    // tick 位图槽位的库
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];        // Oracle 相关操作的库

    uint256 public  feeGrowthGlobal0X128;

    uint256 public  feeGrowthGlobal1X128;

    int24 public   tickSpacing;

    address  private _factory;
    // address public   factory;

    address private   _token0;

    address private   _token1;

    uint24 private   _fee;


    int24 private   _tickSpacing;


    uint128 private   _maxLiquidityPerTick;

    uint128 private  liquidity_;

    int24 private _tickLower;
    int24 private _tickUpper;
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }

    ProtocolFees private  protocolFees;
    // 记录了一个 tick 包含的元数据，这里只会包含所有 Position 的 lower/upper ticks
    mapping(int24 => Tick.Info) public ticks;
    // tick 位图，因为这个位图比较长（一共有 887272x2 个位），大部分的位不需要初始化
    // 因此分成两级来管理，每 256 位为一个单位，一个单位称为一个 word
    // map 中的键是 word 的索引
    mapping(int16 => uint256) private  tickBitmap;
    
    mapping(bytes32 => Position.Info) private  positions_;
    // 使用数据记录 Oracle 的值
    Oracle.Observation[65535] private  observations;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // 记录了最近一次 Oracle 记录在 Oracle 数组中的索引位置
        uint16 observationIndex;
        // 已经存储的 Oracle 数量
        uint16 observationCardinality;
        // 可用的 Oracle 空间，此值初始时会被设置为 1，后续根据需要来可以扩展
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    Slot0 public  slot0;

    function factory() external view override returns (address) {
        return _factory;
    }

    function token0() external view override returns (address) {
        return _token0;
    }

    function token1() external view override returns (address) {
        return _token1;
    }

    function fee() external view override returns (uint24) {
        return _fee;
    }

    function tickLower() external view override returns (int24) {
        return _tickLower;
    }

    function tickUpper() external view override returns (int24) {
        return _tickUpper;
    }

    function sqrtPriceX96() external view override returns (uint160) {
        return slot0.sqrtPriceX96;
    }

    function tick() external view override returns (int24) {
        return slot0.tick;
    }

    function liquidity() external view override returns (uint128) {
        return liquidity_;
    }

    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    function positions(
        int8 positionType
    )
        external
        view
        override
        returns (uint128 _liquidity, uint128 tokensOwed0, uint128 tokensOwed1)
    {
        bytes32 key = bytes32(uint256(uint8(positionType)));
        _liquidity = positions_[key].liquidity;
        tokensOwed0 = positions_[key].tokensOwed0;
        tokensOwed1 = positions_[key].tokensOwed1;
    }

    function initialize(
        uint160 sqrtPriceX96, 
        int24 tickLower_, 
        int24 tickUpper_
        ) external override {
        require(slot0.sqrtPriceX96 == 0, 'AI');

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        // emit Initialize(sqrtPriceX96, tick);
    }

    function mint(
        address recipient,
        int8 positionType,
        uint128 amount,
        bytes calldata data
    ) external override returns (uint256 amount0, uint256 amount1) {

    }

    function collect(
        address recipient,
        int8 positionType
    ) external override returns (uint128 amount0, uint128 amount1) {

    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );
        // 计算三种情况下 amount0 和 amount1 的值，即 x token 和 y token 的数量
        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // 计算 lower/upper tick 对应的价格
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // current tick is inside the passed range
                uint128 liquidityBefore = liquidity_; // SLOAD for gas optimization

                // write an oracle entry
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                liquidity_ = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        // 获取用户的 Postion
        position = positions_.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization

        // 根据传入的参数修改 Position 对应的 lower/upper tick 中
        // 的数据，这里可以是增加流动性，也可以是移出流动性
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity_,
                    slot0.observationCardinality
                );

            // 更新 lower tikc 和 upper tick
            // fippedX 变量表示是此 tick 的引用状态是否发生变化，即
            // 被引用 -> 未被引用 或
            // 未被引用 -> 被引用
            // 后续需要根据这个变量的值来更新 tick 位图
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                _maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                _maxLiquidityPerTick
            );
            // 如果一个 tick 第一次被引用，或者移除了所有引用
            // 那么更新 tick 位图
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);
        // 更新 position 中的数据
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // 如果移除了对 tick 的引用，那么清除之前记录的元数据
        // 这只会发生在移除流动性的操作中
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    function burn(
        int8 positionType
    ) external override returns (uint256 amount0, uint256 amount1) {
        int128 amount;
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: _tickLower,
                    tickUpper: _tickUpper,
                    liquidityDelta: amount
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, positionType, uint128(amount), amount0, amount1);
    }

    struct SwapCache {
        // 转入token的协议费用
        uint8 feeProtocol;
        // swap开始时的流动性
        uint128 liquidityStart;
        // 当前块的时间戳
        uint32 blockTimestamp;
        // 刻度累加器的当前值，仅在经过初始化的刻度时计算
        int56 tickCumulative;
        // 每个流动性累加器的当前秒值，仅在经过初始化的刻度时计算
        uint160 secondsPerLiquidityCumulativeX128;
        // 是否计算并缓存了上面两个累加器
        bool computedLatestObservation;
    }

    // 交换的顶层状态，交换的结果在最后被记录在存储中
    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // 在输入/输出资产中要交换的剩余金额
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // 已交换出/输入的输出/输入资产的数量
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // 当前价格的平方根
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // 与当前价格相关的刻度
        // the tick associated with the current price
        int24 tick;
        // 输入令牌的全球费用增长
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // 作为协议费支付的输入令牌数量
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // 当前流动性在一定范围内
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        // 步骤开始时的价格
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        // 根据当前刻度的交易方向的下一个刻度
        int24 tickNext;
        // whether tickNext is initialized or not
        // 下一个tick是否初始化过（有流动性）
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        // token0的下一个tick平方根价格
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        // 这个步骤多少被交易注入的量，这一步消耗多少
        uint256 amountIn;
        // how much is being swapped out
        // 多少金额被交易输出
        uint256 amountOut;
        // how much fee is being paid in
        // 多少费用需要被被支付，做市商费用
        uint256 feeAmount;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, 'AS');
        // 将交易前的元数据保存在内存中，后续的访问通过 `MLOAD` 完成，节省 gas
        Slot0 memory slot0Start = slot0;

        require(slot0Start.unlocked, 'LOK');
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );
        // 防止交易过程中回调到合约中其他的函数中修改状态变量
        slot0.unlocked = false;
        // 将交易前的元数据保存在内存中，后续的访问通过 `MLOAD` 完成，节省 gas
        SwapCache memory cache =
            SwapCache({
                liquidityStart: liquidity_,
                blockTimestamp: _blockTimestamp(),
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
                secondsPerLiquidityCumulativeX128: 0,
                tickCumulative: 0,
                computedLatestObservation: false
            });
        // 判断是否指定了 tokenIn 的数量
        bool exactInput = amountSpecified > 0;
        // 保存交易过程中计算所需的中间变量，这些值在交易的步骤中可能会发生变化
        SwapState memory state =
            SwapState({
                amountSpecifiedRemaining: amountSpecified,
                amountCalculated: 0,
                sqrtPriceX96: slot0Start.sqrtPriceX96,
                tick: slot0Start.tick,
                feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
                protocolFee: 0,
                liquidity: cache.liquidityStart
            });

        // 交易的主循环，实现思路即以一个 tickBitmap 的 word 为最大单位，在此单位内计算相同流动性区间的交易数值，
        // 如果交易没有完成，那么更新流动性的值，进入下一个流动性区间计算，如果 tick index 移动到 word 的边界，
        // 那么步进到下一个 word.
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            // 通过位图找到下一个可以选的交易价格，这里可能是下一个流动性的边界，也可能还是在本流动性中
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            //获取下一个的价格tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // 计算当价格到达下一个交易价格时，tokenIn 是否被耗尽，如果被耗尽，则交易结束，还需要重新计算出 tokenIn 耗尽时的价格
            // 如果没被耗尽，那么还需要继续进入下一个循环
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                _fee
            );
            // 更新 tokenIn 的余额，以及 tokenOut 数量，注意当指定 tokenIn 的数量进行交易时，这里的 tokenOut 是负数
            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            //如果开启了协议费用，则计算所欠金额，减少feeAmount，并增加protocolFee
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

           //更新全局费用跟踪器
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // 按需决定是否需要更新流动性 L 的值
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // 检查 tick index 是否为另一个流动性的边界
                if (step.initialized) {
                    //检查占位符值，我们在第一次交换时将其替换为实际值
                    //跨越一个已初始化的tick
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    int128 liquidityNet =
                        ticks.cross(
                            step.tickNext,
                            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                            cache.secondsPerLiquidityCumulativeX128,
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    // 根据价格增加/减少，即向左或向右移动，增加/减少相应的流动性
                    // 因为 LiquidityNet 不能为 type(int128).min
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    // 更新流动性
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }
                // 在这里更新 tick 的值，使得下一次循环时让 tickBitmap 进入下一个 word 中查询
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                /// 如果 tokenIn 被耗尽，那么计算当前价格对应的 tick
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        //如果价格变动则更新价格变动并写入 oracle tick
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            //否则只更新价格
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        //如果流动性发生变化则更新
        if (cache.liquidityStart != state.liquidity) liquidity_ = state.liquidity;

        //更新全局费用增长，如有必要，更新协议费用
        //溢出是可以接受的，协议必须在达到 type(uint128).max 费用之前撤回
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }
        // 确定最终用户支付的 token 数和得到的 token 数
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        //// 扣除用户需要支付的 token
        if (zeroForOne) {
            // 将 tokenOut 支付给用户，前面说过 tokenOut 记录的是负数
            if (amount1 < 0) TransferHelper.safeTransfer(_token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            // 还是通过回调的方式，扣除用户需要支持的 token
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            // 校验扣除是否成功
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            if (amount0 < 0) TransferHelper.safeTransfer(_token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }
        // 记录日志
        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        // 解除防止重入的锁
        slot0.unlocked = true;
    }

    /// @dev 获取 token0 余额
    ///@dev 该函数经过了 Gas 优化，以避免除了 returndatasize 之外的冗余 extcodesize 检查
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) =
            _token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @dev 获取 token1 余额
    ///@dev 该函数经过了 Gas 优化，以避免除了 returndatasize 之外的冗余 extcodesize 检查
    ///查看
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            _token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

}