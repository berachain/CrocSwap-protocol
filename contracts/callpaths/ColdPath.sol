// SPDX-License-Identifier: GPL-3

pragma solidity 0.8.19;

import "../libraries/Directives.sol";
import "../libraries/Encoding.sol";
import "../libraries/TokenFlow.sol";
import "../libraries/PriceGrid.sol";
import "../libraries/ProtocolCmd.sol";
import "../mixins/SettleLayer.sol";
import "../mixins/PoolRegistry.sol";
import "../mixins/MarketSequencer.sol";
import "../mixins/StorageLayout.sol";
import "../mixins/ProtocolAccount.sol";
import "../mixins/DepositDesk.sol";
import "../periphery/CrocLpErc20.sol";
import "../interfaces/ICrocMinion.sol";
import "../CrocEvents.sol";

/* @title Cold path callpath sidecar.
 * @notice Defines a proxy sidecar contract that's used to move code outside the 
 *         main contract to avoid Ethereum's contract code size limit. Contains
 *         top-level logic for non trade related logic, including protocol control,
 *         pool initialization, and surplus collateral payment. 
 * 
 * @dev    This exists as a standalone contract but will only ever contain proxy code,
 *         not state. As such it should never be called directly or externally, and should
 *         only be invoked with DELEGATECALL so that it operates on the contract state
 *         within the primary CrocSwap contract. */
contract ColdPath is MarketSequencer, DepositDesk, ProtocolAccount {
    using SafeCast for uint128;
    using TokenFlow for TokenFlow.PairSeq;
    using CurveMath for CurveMath.CurveState;
    using Chaining for Chaining.PairFlow;
    using ProtocolCmd for bytes;

    constructor(address initialWbera) DepositDesk(initialWbera) {}
    /* @notice Consolidated method for protocol control related commands. */

    function protocolCmd(bytes calldata cmd) public {
        uint8 code = uint8(cmd[31]);

        if (code == ProtocolCmd.DISABLE_TEMPLATE_CODE) {
            disableTemplate(cmd);
        } else if (code == ProtocolCmd.POOL_TEMPLATE_CODE) {
            setTemplate(cmd);
        } else if (code == ProtocolCmd.POOL_REVISE_CODE) {
            revisePool(cmd);
        } else if (code == ProtocolCmd.SET_TAKE_CODE) {
            setTakeRate(cmd);
        } else if (code == ProtocolCmd.RELAYER_TAKE_CODE) {
            setRelayerTakeRate(cmd);
        } else if (code == ProtocolCmd.RESYNC_TAKE_CODE) {
            resyncTakeRate(cmd);
        } else if (code == ProtocolCmd.INIT_POOL_LIQ_CODE) {
            setNewPoolLiq(cmd);
        } else if (code == ProtocolCmd.OFF_GRID_CODE) {
            pegPriceImprove(cmd);
        } else {
            revert("Invalid command");
        }

        emit CrocEvents.CrocColdProtocolCmd(cmd);
    }

    function userCmd(bytes calldata cmd) public payable {
        uint8 cmdCode = uint8(cmd[31]);

        if (cmdCode == UserCmd.INIT_POOL_CODE) {
            initPool(cmd);
        } else if (cmdCode == UserCmd.APPROVE_ROUTER_CODE) {
            approveRouter(cmd);
        } else if (cmdCode == UserCmd.DEPOSIT_SURPLUS_CODE) {
            depositSurplus(cmd);
        } else if (cmdCode == UserCmd.DEPOSIT_PERMIT_CODE) {
            depositPermit(cmd);
        } else if (cmdCode == UserCmd.DISBURSE_SURPLUS_CODE) {
            disburseSurplus(cmd);
        } else if (cmdCode == UserCmd.TRANSFER_SURPLUS_CODE) {
            transferSurplus(cmd);
        } else if (cmdCode == UserCmd.SIDE_POCKET_CODE) {
            sidePocketSurplus(cmd);
        } else if (cmdCode == UserCmd.RESET_NONCE) {
            resetNonce(cmd);
        } else if (cmdCode == UserCmd.RESET_NONCE_COND) {
            resetNonceCond(cmd);
        } else if (cmdCode == UserCmd.GATE_ORACLE_COND) {
            checkGateOracle(cmd);
        } else {
            revert("Invalid command");
        }

        emit CrocEvents.CrocColdCmd(cmd);
    }

    /* @notice Initializes the pool type for the pair.
     * @param base The base token in the pair.
     * @param quote The quote token in the pair.
     * @param poolIdx The index of the pool type to initialize.
     * @param price The price to initialize the pool. Represented as square root price in
     *              Q64.64 notation. */
    function initPool(bytes calldata cmd) private {
        (, address base, address quote, uint256 poolIdx, uint128 price) =
            abi.decode(cmd, (uint8, address, address, uint256, uint128));
        bool nativeBera = false;
        if (base == address(0)) {
            base = wbera;
            nativeBera = true;
        } else if (quote == address(0)) {
            quote = wbera;
            nativeBera = true;
        }
        (PoolSpecs.PoolCursor memory pool, uint128 initLiq) = registerPool(base, quote, poolIdx);
        verifyPermitInit(pool, base, quote, poolIdx);

        (int128 baseFlow, int128 quoteFlow) = initCurve(pool, price, initLiq);

        if (nativeBera) {
            if (base == wbera) {
                settleInitFlowBera(lockHolder_, base, baseFlow, quote, quoteFlow);
            } else {
                settleInitFlowBera(lockHolder_, quote, quoteFlow, base, baseFlow);
            }
        } else {
            settleInitFlow(lockHolder_, base, baseFlow, quote, quoteFlow);
        }

        bytes memory bytecode = type(CrocLpErc20).creationCode;
        bool stableSwap = poolIdx == stableSwapPoolIdx_;
        bytes32 salt = keccak256(abi.encodePacked(base, quote, stableSwap));
        address pair;
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        CrocLpErc20(pair).initialize(base, quote, poolIdx);
        emit CrocEvents.BeraCrocLPCreated(base, quote, poolIdx, pair);
    }

    /* @notice Disables an existing pool template. Any previously instantiated pools on
     *         this template will continue exist, but calling this will prevent any new
     *         pools from being created on this template. */
    function disableTemplate(bytes calldata input) private {
        (, uint256 poolIdx) = abi.decode(input, (uint8, uint256));
        emit CrocEvents.DisablePoolTemplate(poolIdx);
        disablePoolTemplate(poolIdx);
    }

    /* @notice Sets template parameters for a pool type index.
     * @param poolIdx The index of the pool type.
     * @param feeRate The pool's swap fee rate in multiples of 0.0001%
     * @param tickSize The pool's grid size in ticks.
     * @param jitThresh The minimum resting time (in seconds) for concentrated LPs.
     * @param knockout The knockout bits for the pool template.
     * @param oracleFlags The oracle bit flags if a permissioned pool. 
     * @param priceFloor The lower limit of price at which mint/burn of concentrated liq is allowed for stable swap pool (defined as square root of actual price).
     * @param priceCeiling The upper limit of price at which mint/burn of concentrated liq is allowed for stable swap pool (defined as square root of actual price).
     * @param isStableSwapPool The stable swap pool flag. */
    function setTemplate(bytes calldata input) private {
        (
            ,
            uint256 poolIdx,
            uint16 feeRate,
            uint16 tickSize,
            uint8 jitThresh,
            uint8 knockout,
            uint8 oracleFlags,
            uint128 priceFloor,
            uint128 priceCeiling,
            bool isStableSwapPool
        ) = abi.decode(input, (uint8, uint256, uint16, uint16, uint8, uint8, uint8, uint128, uint128, bool));

        emit CrocEvents.SetPoolTemplate(
            poolIdx, feeRate, tickSize, jitThresh, knockout, oracleFlags, priceFloor, priceCeiling
        );
        setPoolTemplate(
            poolIdx, feeRate, tickSize, jitThresh, knockout, oracleFlags, priceFloor, priceCeiling, isStableSwapPool
        );
    }

    function setTakeRate(bytes calldata input) private {
        (, uint8 takeRate) = abi.decode(input, (uint8, uint8));

        emit CrocEvents.SetTakeRate(takeRate);
        setProtocolTakeRate(takeRate);
    }

    function setRelayerTakeRate(bytes calldata input) private {
        (, uint8 takeRate) = abi.decode(input, (uint8, uint8));

        emit CrocEvents.SetRelayerTakeRate(takeRate);
        setRelayerTakeRate(takeRate);
    }

    function setNewPoolLiq(bytes calldata input) private {
        (, uint128 liq) = abi.decode(input, (uint8, uint128));

        emit CrocEvents.SetNewPoolLiq(liq);
        setNewPoolLiq(liq);
    }

    function resyncTakeRate(bytes calldata input) private {
        (, address base, address quote, uint256 poolIdx) = abi.decode(input, (uint8, address, address, uint256));

        emit CrocEvents.ResyncTakeRate(base, quote, poolIdx, protocolTakeRate_);
        resyncProtocolTake(base, quote, poolIdx);
    }

    /* @notice Update parameters for a pre-existing pool.
     * @param base The base-side token defining the pool's pair.
     * @param quote The quote-side token defining the pool's pair.
     * @param poolIdx The index of the pool type.
     * @param feeRate The pool's swap fee rate in multiples of 0.0001%
     * @param tickSize The pool's grid size in ticks.
     * @param jitThresh The minimum resting time (in seconds) for concentrated LPs in
     *                  in the pool.
     * @param knockout The knockout bit flags for the pool. 
     * @param priceFloor The lower limit of price at which mint/burn of concentrated liq is allowed for stable swap pool (defined as square root of actual price).
     * @param priceCeiling The upper limit of price at which mint/burn of concentrated liq is allowed for stable swap pool (defined as square root of actual price). */
    function revisePool(bytes calldata cmd) private {
        (
            ,
            address base,
            address quote,
            uint256 poolIdx,
            uint16 feeRate,
            uint16 tickSize,
            uint8 jitThresh,
            uint8 knockout,
            uint128 priceFloor,
            uint128 priceCeiling
        ) = abi.decode(cmd, (uint8, address, address, uint256, uint16, uint16, uint8, uint8, uint128, uint128));
        setPoolSpecs(base, quote, poolIdx, feeRate, tickSize, jitThresh, knockout, priceFloor, priceCeiling);
    }

    /* @notice Set off-grid price improvement.
     * @param token The token the settings apply to.
     * @param unitTickCollateral The collateral threshold for off-grid price improvement.
     * @param awayTickTol The maximum tick distance from current price that off-grid
     *                    quotes are allowed for. */
    function pegPriceImprove(bytes calldata cmd) private {
        (, address token, uint128 unitTickCollateral, uint16 awayTickTol) =
            abi.decode(cmd, (uint8, address, uint128, uint16));
        emit CrocEvents.PriceImproveThresh(token, unitTickCollateral, awayTickTol);
        setPriceImprove(token, unitTickCollateral, awayTickTol);
    }

    /* @notice Used to directly pay out or pay in surplus collateral.
     * @param recv The address where the funds are paid to (only applies if surplus was
     *             paid out.)
     * @param value The amount of surplus collateral being paid or received. If negative
     *              paid from the user into the pool, increasing their balance.
     * @param token The token to which the surplus collateral is applied. (If 0x0, then
     *              native Ethereum) */
    function depositSurplus(bytes calldata cmd) private {
        (, address recv, uint128 value, address token) = abi.decode(cmd, (uint8, address, uint128, address));
        depositSurplus(recv, value, token);
    }

    function depositPermit(bytes calldata cmd) private {
        (, address recv, uint128 value, address token, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(cmd, (uint8, address, uint128, address, uint256, uint8, bytes32, bytes32));
        depositSurplusPermit(recv, value, token, deadline, v, r, s);
    }

    function disburseSurplus(bytes calldata cmd) private {
        (, address recv, int128 value, address token) = abi.decode(cmd, (uint8, address, int128, address));
        disburseSurplus(recv, value, token);
    }

    function transferSurplus(bytes calldata cmd) private {
        (, address recv, int128 size, address token) = abi.decode(cmd, (uint8, address, int128, address));
        transferSurplus(recv, size, token);
    }

    function sidePocketSurplus(bytes calldata cmd) private {
        (, uint256 fromSalt, uint256 toSalt, int128 value, address token) =
            abi.decode(cmd, (uint8, uint256, uint256, int128, address));
        sidePocketSurplus(fromSalt, toSalt, value, token);
    }

    function resetNonce(bytes calldata cmd) private {
        (, bytes32 salt, uint32 nonce) = abi.decode(cmd, (uint8, bytes32, uint32));
        resetNonce(salt, nonce);
    }

    function resetNonceCond(bytes calldata cmd) private {
        (, bytes32 salt, uint32 nonce, address oracle, bytes memory args) =
            abi.decode(cmd, (uint8, bytes32, uint32, address, bytes));
        resetNonceCond(salt, nonce, oracle, args);
    }

    function checkGateOracle(bytes calldata cmd) private {
        (, address oracle, bytes memory args) = abi.decode(cmd, (uint8, address, bytes));
        checkGateOracle(oracle, args);
    }

    /* @notice Called by a user to give permissions to an external smart contract router.
     * @param router The address of the external smart contract that the user is giving
     *                permission to.
     * @param nCalls The number of calls the router agent is approved for.
     * @param callpaths The proxy sidecar indexes the router is approved for */
    function approveRouter(bytes calldata cmd) private {
        (, address router, uint32 nCalls, uint16[] memory callpaths) =
            abi.decode(cmd, (uint8, address, uint32, uint16[]));

        for (uint256 i = 0; i < callpaths.length; ++i) {
            require(callpaths[i] != CrocSlots.COLD_PROXY_IDX, "Invalid Router Approve");
            approveAgent(router, nCalls, callpaths[i]);
        }
    }

    /* @notice Used at upgrade time to verify that the contract is a valid Croc sidecar proxy and used
     *         in the correct slot. */
    function acceptCrocProxyRole(address, uint16 slot) public pure returns (bool) {
        return slot == CrocSlots.COLD_PROXY_IDX;
    }
}
