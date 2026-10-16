// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TilePacking
/// @notice One 256-bit word per tile. Terrain is NOT stored: it is derived from the season seed
///         (see Terrain.sol), so a tile only costs one SLOAD/SSTORE when touched.
///
///  bits   0..23   owner      (player id, 0 = unowned)
///  bits  24..31   building   (0 none, 1 farm, 2 mine, 3 fort)
///  bits  32..63   garrison   (troops on the tile)
///  bits 64..255   reserved
library TilePacking {
    uint256 internal constant OWNER_MASK = (1 << 24) - 1;
    uint256 internal constant BUILDING_SHIFT = 24;
    uint256 internal constant BUILDING_MASK = 0xFF;
    uint256 internal constant GARRISON_SHIFT = 32;
    uint256 internal constant GARRISON_MASK = (1 << 32) - 1;

    uint8 internal constant B_NONE = 0;
    uint8 internal constant B_FARM = 1;
    uint8 internal constant B_MINE = 2;
    uint8 internal constant B_FORT = 3;

    function owner(uint256 t) internal pure returns (uint24) {
        return uint24(t & OWNER_MASK);
    }

    function building(uint256 t) internal pure returns (uint8) {
        return uint8((t >> BUILDING_SHIFT) & BUILDING_MASK);
    }

    function garrison(uint256 t) internal pure returns (uint32) {
        return uint32((t >> GARRISON_SHIFT) & GARRISON_MASK);
    }

    function pack(uint24 owner_, uint8 building_, uint32 garrison_) internal pure returns (uint256) {
        return
            uint256(owner_) | (uint256(building_) << BUILDING_SHIFT) | (uint256(garrison_) << GARRISON_SHIFT);
    }

    function setOwner(uint256 t, uint24 v) internal pure returns (uint256) {
        return (t & ~OWNER_MASK) | uint256(v);
    }

    function setBuilding(uint256 t, uint8 v) internal pure returns (uint256) {
        return (t & ~(BUILDING_MASK << BUILDING_SHIFT)) | (uint256(v) << BUILDING_SHIFT);
    }

    function setGarrison(uint256 t, uint32 v) internal pure returns (uint256) {
        return (t & ~(GARRISON_MASK << GARRISON_SHIFT)) | (uint256(v) << GARRISON_SHIFT);
    }
}
