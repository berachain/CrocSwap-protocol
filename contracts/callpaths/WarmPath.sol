// SPDX-License-Identifier: GPL-3

pragma solidity 0.8.19;

import '../libraries/BaseERC20.sol';
import '../libraries/Directives.sol';
import '../libraries/Encoding.sol';
import '../libraries/PriceGrid.sol';
import '../libraries/ProtocolCmd.sol';
import '../libraries/TokenFlow.sol';
import '../mixins/MarketSequencer.sol';
import '../mixins/SettleLayer.sol';
import '../mixins/PoolRegistry.sol';
import '../mixins/MarketSequencer.sol';
import '../mixins/ProtocolAccount.sol';
import '../CrocEvents.sol';

/* @title Warm path callpath sidecar.
 * @notice Defines a proxy sidecar contract that's used to move code outside the 
 *         main contract to avoid Ethereum's contract code size limit. Contains top-
 *         level logic for the core liquidity provider actions:
 *              * Mint ambient liquidity
 *              * Mint concentrated range liquidity
 *              * Burn ambient liquidity
 *              * Burn concentrated range liquidity
 *         These methods are exposed as atomic single-action calls. Useful for traders
 *         who only need to execute a single action, and want to get the lowest gas fee
 *         possible. Compound calls are available in LongPath, but the overhead with
 *         parsing a longer OrderDirective makes the gas cost higher.
 * 
 * @dev    This exists as a standalone contract but will only ever contain proxy code,
 *         not state. As such it should never be called directly or externally, and should
 *         only be invoked with DELEGATECALL so that it operates on the contract state
 *         within the primary CrocSwap contract. */
contract WarmPath is MarketSequencer, SettleLayer, ProtocolAccount {

    using TickMath for int24;
    using SafeCast for uint128;
    using TokenFlow for TokenFlow.PairSeq;
    using CurveMath for CurveMath.CurveState;
    using Chaining for Chaining.PairFlow;

    constructor(address initialWbera) SettleLayer(initialWbera) {
    }
    
    /* @notice Consolidated method for all atomic liquidity provider actions.
     * @dev    We consolidate multiple call types into a single method to reduce the 
     *         contract size in the main contract by paring down methods.
     * 
     * @param code The command code corresponding to the actual method being called. */
    function userCmd (bytes calldata input) public payable returns
        (int128 baseFlow, int128 quoteFlow) {
        
        (uint8 code, address base, address quote, uint256 poolIdx,
         int24 bidTick, int24 askTick, uint128 liq,
         uint128 limitLower, uint128 limitHigher,
         uint8 reserveFlags, address lpConduit) =
            abi.decode(input, (uint8,address,address,uint256,int24,int24,
                               uint128,uint128,uint128,uint8,address));

        // Ensure reserve flags are valid
        require(reserveFlags < 0x4, "RF");

        if (base == address(0)) {
            require(!isBurnOrHarvest(code), "WB");
            base = wbera;
            reserveFlags = 0x4;
        }

        if (quote == address(0)) {
            require(!isBurnOrHarvest(code), "WB");
            quote = wbera;
            reserveFlags = 0x5;
        }

        if (lpConduit == address(0)) { lpConduit = lockHolder_; }
        
        (baseFlow, quoteFlow) =
            commitLP(code, base, quote, poolIdx, bidTick, askTick,
                     liq, limitLower, limitHigher, lpConduit);
        settleFlows(base, quote, baseFlow, quoteFlow, reserveFlags);

        emit CrocEvents.CrocWarmCmd(input, baseFlow, quoteFlow);
    }

    
    function commitLP (uint8 code, address base, address quote, uint256 poolIdx,
                       int24 bidTick, int24 askTick, uint128 liq,
                       uint128 limitLower, uint128 limitHigher,
                       address lpConduit)
        private returns (int128, int128) {
        
        // Allow Harvest on any pool
        if (code == UserCmd.HARVEST_LP) {
            return harvest(base, quote, poolIdx, bidTick, askTick, lpConduit,
                        limitLower, limitHigher);
        }
        // Allow concentrated liquidity actions only on stable swap pools
        if (poolIdx == stableSwapPoolIdx_) {
            PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
            // Override the bid and ask ticks for stable swap pools
            (bidTick, askTick) = _calculateBidAskTick(base, quote, pool.head_);
            if (code == UserCmd.MINT_RANGE_LIQ_LP) {
                return mintConcentratedLiq(base, quote, poolIdx, bidTick, askTick, liq, lpConduit,
                        limitLower, limitHigher);
            } else if (code == UserCmd.MINT_RANGE_BASE_LP) {
                return mintConcentratedQty(base, quote, poolIdx, bidTick, askTick, true, liq, lpConduit,
                            limitLower, limitHigher);
            } else if (code == UserCmd.MINT_RANGE_QUOTE_LP) {
                return mintConcentratedQty(base, quote, poolIdx, bidTick, askTick, false, liq, lpConduit,
                            limitLower, limitHigher);
            } else if (code == UserCmd.BURN_RANGE_LIQ_LP) {
                return burnConcentratedLiq(base, quote, poolIdx, bidTick, askTick, liq, lpConduit,
                            limitLower, limitHigher);
            } else if (code == UserCmd.BURN_RANGE_BASE_LP) {
                return burnConcentratedQty(base, quote, poolIdx, bidTick, askTick, true, liq, lpConduit,
                            limitLower, limitHigher);
            } else if (code == UserCmd.BURN_RANGE_QUOTE_LP) {
                return burnConcentratedQty(base, quote, poolIdx, bidTick, askTick, false, liq, lpConduit,
                            limitLower, limitHigher);
            }
        // Allow ambient liquidity actions only on non-stable swap pools
        } else {
            if (code == UserCmd.MINT_AMBIENT_LIQ_LP) {
                return mintAmbientLiq(base, quote, poolIdx, liq, lpConduit, limitLower, limitHigher);
            } else if (code == UserCmd.MINT_AMBIENT_BASE_LP) {
                return mintAmbientQty(base, quote, poolIdx, true, liq, lpConduit,
                            limitLower, limitHigher);
            } else if (code == UserCmd.MINT_AMBIENT_QUOTE_LP) {
                return mintAmbientQty(base, quote, poolIdx, false, liq, lpConduit,
                            limitLower, limitHigher);   
            } else if (code == UserCmd.BURN_AMBIENT_LIQ_LP) {
                return burnAmbientLiq(base, quote, poolIdx, liq, lpConduit, limitLower, limitHigher);
            } else if (code == UserCmd.BURN_AMBIENT_BASE_LP) {
                return burnAmbientQty(base, quote, poolIdx, true, liq, lpConduit,
                            limitLower, limitHigher);
            } else if (code == UserCmd.BURN_AMBIENT_QUOTE_LP) {
                return burnAmbientQty(base, quote, poolIdx, false, liq, lpConduit,
                            limitLower, limitHigher);
            } else if (code == UserCmd.HARVEST_LP) {
                return harvest(base, quote, poolIdx, bidTick, askTick, lpConduit,
                            limitLower, limitHigher);
            }
        }
        revert("Invalid command");
    }

/* @notice Mints liquidity as a concentrated liquidity range order.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being minted on.
     * @param bidTick The price tick index of the lower boundary of the range order.
     * @param askTick The price tick index of the upper boundary of the range order.
     * @param liq The total amount of liquidity being minted. Represented as sqrt(X*Y)
     *            for the equivalent constant-product AMM.
     * @param lpConduit The address of the LP conduit to deposit the minted position at
     *                  (direct owned liquidity if 0)
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is minted at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold.  */    
    function mintConcentratedLiq (address base, address quote, uint256 poolIdx,
                   int24 bidTick, int24 askTick, uint128 liq, address lpConduit, 
                   uint128 limitLower, uint128 limitHigher) internal returns
        (int128, int128) {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        verifyPermitMint(pool, base, quote, bidTick, askTick, liq);

        return mintOverPool(bidTick, askTick, liq, pool, limitLower, limitHigher,
                            lpConduit);
    }
    
    /* @notice Burns liquidity as a concentrated liquidity range order.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being burned on.
     * @param bidTick The price tick index of the lower boundary of the range order.
     * @param askTick The price tick index of the upper boundary of the range order.
     * @param liq The total amount of liquidity being burned. Represented as sqrt(X*Y)
     *            for the equivalent constant-product AMM.
     * @param lpConduit The address of the LP conduit to deposit the minted position at
     *                  (direct owned liquidity if 0)
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is burned at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold. */
    function burnConcentratedLiq (address base, address quote, uint256 poolIdx,
                   int24 bidTick, int24 askTick, uint128 liq, address lpConduit, 
                   uint128 limitLower, uint128 limitHigher)
        internal returns (int128, int128) {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        verifyPermitBurn(pool, base, quote, bidTick, askTick, liq);
        
        return burnOverPool(bidTick, askTick, liq, pool, limitLower, limitHigher, lpConduit);
    }

    /* @notice Harvests the rewards for a concentrated liquidity position.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being burned on.
     * @param bidTick The price tick index of the lower boundary of the range order.
     * @param askTick The price tick index of the upper boundary of the range order.
     * @param lpConduit The address of the LP conduit to deposit the minted position at
     *                  (direct owned liquidity if 0)
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is burned at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold. */
    function harvest (address base, address quote, uint256 poolIdx,
                      int24 bidTick, int24 askTick, address lpConduit,
                      uint128 limitLower, uint128 limitHigher)
        internal returns (int128, int128) {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        
        // On permissioned pools harvests are treated like a special case burn
        // with 0 liquidity. Note that unlike a true 0 burn, ambient liquidity will still
        // be returned, so oracles should handle 0 as special case if that's an issue. 
        verifyPermitBurn(pool, base, quote, bidTick, askTick, 0);
        
        return harvestOverPool(bidTick, askTick, pool, limitLower, limitHigher,
                               lpConduit);
    }

    /* @notice Mints ambient liquidity that's active at every price.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being minted on.
     * @param liq The total amount of liquidity being minted. Represented as sqrt(X*Y)
     *            for the equivalent constant-product AMM.
     @ @param lpConduit The address of the LP conduit to deposit the minted position at
     *                  (direct owned liquidity if 0)
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is minted at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold.  */
    function mintAmbientLiq (address base, address quote, uint256 poolIdx, uint128 liq,
                   address lpConduit, uint128 limitLower, uint128 limitHigher) internal
        returns (int128, int128) {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        verifyPermitMint(pool, base, quote, 0, 0, liq);
        return mintOverPool(liq, pool, limitLower, limitHigher, lpConduit);
    }

    function mintAmbientQty (address base, address quote, uint256 poolIdx, bool inBase,
                      uint128 qty, address lpConduit, uint128 limitLower,
                      uint128 limitHigher) internal
        returns (int128, int128) {
        bytes32 poolKey = PoolSpecs.encodeKey(base, quote, poolIdx);
        // bytes memory reee = abi.encodePacked(poolKey);

        // bytes32 littleEndianPoolKey = bytes32(abi.encodePacked(poolIdx));
        
        CurveMath.CurveState memory curve = snapCurve(poolKey);
        uint128 liq = Chaining.sizeAmbientLiq(qty, true, curve.priceRoot_, inBase);
        (int128 baseFlow, int128 quoteFlow) =
            mintAmbientLiq(base, quote, poolIdx, liq, lpConduit, limitLower, limitHigher);
        return Chaining.pinFlow(baseFlow, quoteFlow, qty, inBase);
    }

    function mintConcentratedQty (address base, address quote, uint256 poolIdx,
                      int24 bidTick, int24 askTick, bool inBase,
                      uint128 qty, address lpConduit, uint128 limitLower,
                      uint128 limitHigher) internal
        returns (int128, int128) {
        uint128 liq = sizeAddLiq(base, quote, poolIdx, qty, bidTick, askTick, inBase);
        (int128 baseFlow, int128 quoteFlow) =
            mintConcentratedLiq(base, quote, poolIdx, bidTick, askTick, liq, lpConduit,
                 limitLower, limitHigher);
        return Chaining.pinFlow(baseFlow, quoteFlow, qty, inBase);
            
    }

    function sizeAddLiq (address base, address quote, uint256 poolIdx, uint128 qty,
                         int24 bidTick, int24 askTick, bool inBase)
        internal view returns (uint128) {
        bytes32 poolKey = PoolSpecs.encodeKey(base, quote, poolIdx);
        CurveMath.CurveState memory curve = snapCurve(poolKey);
        return Chaining.sizeConcLiq(qty, true, curve.priceRoot_,
                                    bidTick, askTick, inBase);
    }

    /* @notice Burns ambient liquidity that's active at every price.
     * @param base The base-side token in the pair.
     * @param quote The quote-side token in the par.
     * @param poolIdx The index of the pool type being burned on.
     * @param liq The total amount of liquidity being burned. Represented as sqrt(X*Y)
     *            for the equivalent constant-product AMM.
     * @param limitLower Exists to make sure the user is happy with the price the 
     *                   liquidity is burned at. Transaction fails if the curve price
     *                   at call time is below this value.
     * @param limitUpper Transaction fails if the curve price at call time is above this
     *                   threshold. */
    function burnAmbientLiq (address base, address quote, uint256 poolIdx, uint128 liq,
                   address lpConduit, uint128 limitLower, uint128 limitHigher) internal
        returns (int128, int128) {
        PoolSpecs.PoolCursor memory pool = queryPool(base, quote, poolIdx);
        verifyPermitBurn(pool, base, quote, 0, 0, liq);
        return burnOverPool(liq, pool, limitLower, limitHigher, lpConduit);
    }

    function burnAmbientQty (address base, address quote, uint256 poolIdx, bool inBase,
                      uint128 qty, address lpConduit,
                      uint128 limitLower, uint128 limitHigher) internal
        returns (int128, int128) {
        bytes32 poolKey = PoolSpecs.encodeKey(base, quote, poolIdx);
        CurveMath.CurveState memory curve = snapCurve(poolKey);
        uint128 liq = Chaining.sizeAmbientLiq(qty, false, curve.priceRoot_, inBase);
        return burnAmbientLiq(base, quote, poolIdx, liq, lpConduit,
                    limitLower, limitHigher);
    }

    function burnConcentratedQty (address base, address quote, uint256 poolIdx,
                      int24 bidTick, int24 askTick, bool inBase,
                      uint128 qty, address lpConduit,
                      uint128 limitLower, uint128 limitHigher)
        internal returns (int128, int128) {
        bytes32 poolKey = PoolSpecs.encodeKey(base, quote, poolIdx);
        CurveMath.CurveState memory curve = snapCurve(poolKey);
        uint128 liq = Chaining.sizeConcLiq(qty, false, curve.priceRoot_,
                                           bidTick, askTick, inBase);
        return burnConcentratedLiq(base, quote, poolIdx, bidTick, askTick,
                    liq, lpConduit, limitLower, limitHigher);
    }
    
    /* @notice Used at upgrade time to verify that the contract is a valid Croc sidecar proxy and used
     *         in the correct slot. */
    function acceptCrocProxyRole (address, uint16 slot) public pure returns (bool) {
        return slot == CrocSlots.LP_PROXY_IDX;
    }

    function isBurnOrHarvest (uint8 code) internal pure returns (bool) {
        return code == UserCmd.BURN_AMBIENT_LIQ_LP ||
               code == UserCmd.BURN_AMBIENT_BASE_LP ||
               code == UserCmd.BURN_AMBIENT_QUOTE_LP ||
               code == UserCmd.HARVEST_LP ||
               code == UserCmd.BURN_RANGE_BASE_LP ||
               code == UserCmd.BURN_RANGE_QUOTE_LP ||
               code == UserCmd.BURN_RANGE_LIQ_LP;
    }

    /* @notice Validate that the pool is stable swap and bid and ask ticks are in correct range for providing concentrated liquidity.
     * @dev This is a helper function to validate the concentrated liquidity minting and burning.
     * @param base The base token address.
     * @param quote The quote token address.
     * @param poolIdx The pool index.
     * @param pool The pool specification. */
    function _calculateBidAskTick (address base, address quote,
                      PoolSpecs.Pool memory pool)
        internal view returns (int24 bidTick, int24 askTick) {
        // get the decimal of the base and quote token.
        uint8 baseTokenDecimal = _getTokenDecimals(base);
        uint8 quoteTokenDecimal = _getTokenDecimals(quote);

        uint128 priceRootAtBidTick = pool.priceFloor_;
        uint128 priceRootAtAskTick = pool.priceCeiling_;
        
        if(quoteTokenDecimal > baseTokenDecimal) {
            priceRootAtBidTick = uint128(priceRootAtBidTick * 10**(quoteTokenDecimal - baseTokenDecimal));
            priceRootAtAskTick = uint128(priceRootAtAskTick * 10**(quoteTokenDecimal - baseTokenDecimal));
        }
        else if(quoteTokenDecimal < baseTokenDecimal) {
            priceRootAtBidTick = uint128(priceRootAtBidTick * 10**(baseTokenDecimal - quoteTokenDecimal));
            priceRootAtAskTick = uint128(priceRootAtAskTick * 10**(baseTokenDecimal - quoteTokenDecimal));
        }

        bidTick = TickMath.getTickAtSqrtRatio(priceRootAtBidTick);
        askTick = TickMath.getTickAtSqrtRatio(priceRootAtAskTick);
    }

    /* @notice Get the decimal of the token.
     * @dev If the token does not have decimal, will return 18 as default.
     * @param token The token address.
     * @return The decimal of the token. */
    function _getTokenDecimals(address token) internal view returns (uint8) {
        try ERC20(token).decimals() returns (uint8 tokenDecimals) {
            return tokenDecimals;
        } catch {
            return 18;
        }
    }
}
