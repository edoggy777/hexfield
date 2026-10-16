// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Terrain
/// @notice Deterministic terrain from (seed, tile). Never stored; recomputed on demand (pure, ~300 gas).
///         Clumping: 70% of tiles take the terrain of their 3x3 "cluster", 30% roll independently,
///         which gives contiguous biomes with ragged edges without any noise library.
library Terrain {
    uint8 internal constant PLAINS = 0;
    uint8 internal constant FOREST = 1;
    uint8 internal constant HILLS = 2;
    uint8 internal constant WATER = 3;

    function at(bytes32 seed, uint32 x, uint32 y) internal pure returns (uint8) {
        bytes32 own = keccak256(abi.encodePacked(seed, x, y));
        bytes32 cluster = keccak256(abi.encodePacked(seed, uint8(0xC1), x / 3, y / 3));
        uint8 pick = uint8(own[0]) < 179 ? uint8(cluster[1]) : uint8(own[1]);
        if (pick < 128) return PLAINS; // 50%
        if (pick < 192) return FOREST; // 25%
        if (pick < 230) return HILLS; // ~15%
        return WATER; // ~10%
    }

    function isLand(uint8 t) internal pure returns (bool) {
        return t != WATER;
    }

    /// @dev Defensive multiplier in basis points (10000 = 1x).
    function defenseBps(uint8 t) internal pure returns (uint256) {
        if (t == HILLS) return 15000;
        if (t == FOREST) return 12500;
        return 10000;
    }

    /// @dev Base per-block yield of an owned tile with no building: (grain, ore).
    function baseYield(uint8 t) internal pure returns (uint16 grain, uint16 ore) {
        if (t == PLAINS) return (2, 0);
        if (t == FOREST) return (1, 0);
        if (t == HILLS) return (0, 1);
        return (0, 0);
    }
}
