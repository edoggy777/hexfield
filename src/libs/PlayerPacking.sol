// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PlayerPacking
/// @notice One 256-bit word per player. Resources accrue lazily: the stored grain/ore are the
///         amounts as of `lastSettled`; the live balance is stored + rate * (block.number - lastSettled).
///
///  bits   0..23    id           (1-based, 0 = not registered)
///  bits  24..63    grain        (u40)
///  bits  64..103   ore          (u40)
///  bits 104..119   grainRate    (u16, per block)
///  bits 120..135   oreRate      (u16, per block)
///  bits 136..167   lastSettled  (u32, block number)
///  bits 168..183   tileCount    (u16)
///  bits 184..207   score        (u24)
///  bits 208..239   spawnTile    (u32)
///  bits 240..255   reserved
library PlayerPacking {
    uint256 internal constant M24 = (1 << 24) - 1;
    uint256 internal constant M40 = (1 << 40) - 1;
    uint256 internal constant M16 = (1 << 16) - 1;
    uint256 internal constant M32 = (1 << 32) - 1;

    uint256 internal constant S_GRAIN = 24;
    uint256 internal constant S_ORE = 64;
    uint256 internal constant S_GRATE = 104;
    uint256 internal constant S_ORATE = 120;
    uint256 internal constant S_SETTLED = 136;
    uint256 internal constant S_TILES = 168;
    uint256 internal constant S_SCORE = 184;
    uint256 internal constant S_SPAWN = 208;

    struct P {
        uint24 id;
        uint40 grain;
        uint40 ore;
        uint16 grainRate;
        uint16 oreRate;
        uint32 lastSettled;
        uint16 tileCount;
        uint24 score;
        uint32 spawnTile;
    }

    function unpack(uint256 w) internal pure returns (P memory p) {
        p.id = uint24(w & M24);
        p.grain = uint40((w >> S_GRAIN) & M40);
        p.ore = uint40((w >> S_ORE) & M40);
        p.grainRate = uint16((w >> S_GRATE) & M16);
        p.oreRate = uint16((w >> S_ORATE) & M16);
        p.lastSettled = uint32((w >> S_SETTLED) & M32);
        p.tileCount = uint16((w >> S_TILES) & M16);
        p.score = uint24((w >> S_SCORE) & M24);
        p.spawnTile = uint32((w >> S_SPAWN) & M32);
    }

    function pack(P memory p) internal pure returns (uint256 w) {
        w = uint256(p.id) | (uint256(p.grain) << S_GRAIN) | (uint256(p.ore) << S_ORE)
            | (uint256(p.grainRate) << S_GRATE) | (uint256(p.oreRate) << S_ORATE)
            | (uint256(p.lastSettled) << S_SETTLED) | (uint256(p.tileCount) << S_TILES)
            | (uint256(p.score) << S_SCORE) | (uint256(p.spawnTile) << S_SPAWN);
    }

    function id(uint256 w) internal pure returns (uint24) {
        return uint24(w & M24);
    }

    /// @dev Advance the lazy accrual to `blockNumber`. Saturates at u40 so a long-idle player cannot
    ///      overflow and brick their own account.
    function settle(P memory p, uint256 blockNumber) internal pure {
        if (blockNumber <= p.lastSettled) return;
        uint256 elapsed = blockNumber - p.lastSettled;
        uint256 g = uint256(p.grain) + elapsed * p.grainRate;
        uint256 o = uint256(p.ore) + elapsed * p.oreRate;
        p.grain = g > M40 ? uint40(M40) : uint40(g);
        p.ore = o > M40 ? uint40(M40) : uint40(o);
        p.lastSettled = uint32(blockNumber);
    }

    /// @dev Live balances without mutating.
    function liveBalances(P memory p, uint256 blockNumber)
        internal
        pure
        returns (uint256 grain, uint256 ore)
    {
        uint256 elapsed = blockNumber > p.lastSettled ? blockNumber - p.lastSettled : 0;
        grain = uint256(p.grain) + elapsed * p.grainRate;
        ore = uint256(p.ore) + elapsed * p.oreRate;
        if (grain > M40) grain = M40;
        if (ore > M40) ore = M40;
    }
}
