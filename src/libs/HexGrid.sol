// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HexGrid
/// @notice Rectangular hex map in "odd-r" offset coordinates (pointy-top hexes, odd rows shifted right).
///         Tile ids are row-major: id = y * width + x.
library HexGrid {
    error OutOfBounds();

    function toId(uint32 x, uint32 y, uint32 width) internal pure returns (uint32) {
        return y * width + x;
    }

    function toXY(uint32 id, uint32 width) internal pure returns (uint32 x, uint32 y) {
        x = id % width;
        y = id / width;
    }

    function inBounds(uint32 id, uint32 width, uint32 height) internal pure returns (bool) {
        return id < width * height;
    }

    /// @dev True if `a` and `b` are distinct neighbouring hexes.
    function isAdjacent(uint32 a, uint32 b, uint32 width, uint32 height) internal pure returns (bool) {
        if (a == b) return false;
        if (!inBounds(a, width, height) || !inBounds(b, width, height)) return false;
        (uint32 ax, uint32 ay) = toXY(a, width);
        (uint32 bx, uint32 by) = toXY(b, width);

        int256 dx = int256(uint256(bx)) - int256(uint256(ax));
        int256 dy = int256(uint256(by)) - int256(uint256(ay));

        if (dy == 0) return dx == 1 || dx == -1;
        if (dy != 1 && dy != -1) return false;

        // Odd-r: on an odd row, diagonal neighbours are at dx in {0, +1}; on an even row, {-1, 0}.
        if (ay & 1 == 1) return dx == 0 || dx == 1;
        return dx == 0 || dx == -1;
    }

    /// @dev The up-to-6 neighbours of `id`. Entries beyond `count` are garbage.
    function neighbors(uint32 id, uint32 width, uint32 height)
        internal
        pure
        returns (uint32[6] memory out, uint256 count)
    {
        (uint32 x, uint32 y) = toXY(id, width);
        bool odd = (y & 1) == 1;

        // dx offsets for the two diagonal rows
        int256 dl = odd ? int256(0) : int256(-1);
        int256 dr = odd ? int256(1) : int256(0);

        int256[2][6] memory d = [
            [int256(1), int256(0)],
            [int256(-1), int256(0)],
            [dl, int256(-1)],
            [dr, int256(-1)],
            [dl, int256(1)],
            [dr, int256(1)]
        ];

        for (uint256 i = 0; i < 6; i++) {
            int256 nx = int256(uint256(x)) + d[i][0];
            int256 ny = int256(uint256(y)) + d[i][1];
            if (nx < 0 || ny < 0 || nx >= int256(uint256(width)) || ny >= int256(uint256(height))) continue;
            out[count++] = toId(uint32(uint256(nx)), uint32(uint256(ny)), width);
        }
    }
}
