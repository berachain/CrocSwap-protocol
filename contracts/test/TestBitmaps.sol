// SPDX-License-Identifier: GPL-3
pragma solidity 0.8.19;

import "../libraries/Bitmaps.sol";

contract TestBitmapsLib {
    using Bitmaps for uint256;
    using Bitmaps for int24;

    function testTruncateLeft(uint256 bitmap, uint8 shift) public pure returns (uint256) {
        return bitmap.truncateBitmap(shift, false);
    }

    function testTruncateRight(uint256 bitmap, uint8 shift) public pure returns (uint256) {
        return bitmap.truncateBitmap(shift, true);
    }

    function testBitLeft(uint256 bitmap, uint8 shift) public pure returns (uint8, bool) {
        return bitmap.bitAfterTrunc(shift, false);
    }

    function testBitRight(uint256 bitmap, uint8 shift) public pure returns (uint8, bool) {
        return bitmap.bitAfterTrunc(shift, true);
    }

    function testBitSet(uint256 bitmap, uint8 pos) public pure returns (bool) {
        return bitmap.isBitSet(pos);
    }

    function testShiftBump(int24 tick, bool isBuy) public pure returns (uint16) {
        return tick.termBump(isBuy);
    }

    function testCastIndex(int8 x) public pure returns (uint8) {
        return Bitmaps.castBitmapIndex(x);
    }

    function testUncastIndex(uint8 x) public pure returns (int8) {
        return Bitmaps.uncastBitmapIndex(x);
    }

    function testDecomp(int24 tick)
        public
        pure
        returns (int8 lobbyKey, int16 mezzKey, uint8 lobbyBit, uint8 mezzBit, uint8 termBit)
    {
        lobbyKey = tick.lobbyKey();
        mezzKey = tick.mezzKey();
        lobbyBit = tick.lobbyBit();
        mezzBit = tick.mezzBit();
        termBit = tick.termBit();
    }

    function testWeld(int8 lobbyIdx, uint8 mezzBit, uint8 termBit)
        public
        pure
        returns (int24 fullWeld, int16 mezzWeld, int24 termWeld)
    {
        fullWeld = Bitmaps.weldLobbyMezzTerm(lobbyIdx, mezzBit, termBit);
        mezzWeld = Bitmaps.weldLobbyMezz(lobbyIdx, mezzBit);
        termWeld = Bitmaps.weldMezzTerm(mezzWeld, termBit);
    }
}
