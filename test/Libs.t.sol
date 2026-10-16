// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TilePacking as T} from "../src/libs/TilePacking.sol";
import {PlayerPacking as PP} from "../src/libs/PlayerPacking.sol";
import {HexGrid} from "../src/libs/HexGrid.sol";
import {Terrain} from "../src/libs/Terrain.sol";
import {SSTORE2} from "../src/libs/SSTORE2.sol";

contract LibsTest is Test {
    // ---------------------------------------------------------------- TilePacking

    function testFuzz_tileRoundTrip(uint24 owner, uint8 building, uint32 garrison) public pure {
        uint256 t = T.pack(owner, building, garrison);
        assertEq(T.owner(t), owner);
        assertEq(T.building(t), building);
        assertEq(T.garrison(t), garrison);
    }

    function testFuzz_tileSetters(uint24 o1, uint8 b1, uint32 g1, uint24 o2, uint8 b2, uint32 g2)
        public
        pure
    {
        uint256 t = T.pack(o1, b1, g1);
        t = T.setOwner(t, o2);
        assertEq(T.owner(t), o2);
        assertEq(T.building(t), b1);
        assertEq(T.garrison(t), g1);
        t = T.setBuilding(t, b2);
        assertEq(T.building(t), b2);
        assertEq(T.garrison(t), g1);
        t = T.setGarrison(t, g2);
        assertEq(T.garrison(t), g2);
        assertEq(T.owner(t), o2);
        assertEq(T.building(t), b2);
    }

    // ---------------------------------------------------------------- PlayerPacking

    function testFuzz_playerRoundTrip(
        uint24 id,
        uint40 grain,
        uint40 ore,
        uint16 gr,
        uint16 or,
        uint32 ls,
        uint16 tc,
        uint24 sc,
        uint32 sp
    ) public pure {
        PP.P memory p = PP.P(id, grain, ore, gr, or, ls, tc, sc, sp);
        PP.P memory q = PP.unpack(PP.pack(p));
        assertEq(q.id, id);
        assertEq(q.grain, grain);
        assertEq(q.ore, ore);
        assertEq(q.grainRate, gr);
        assertEq(q.oreRate, or);
        assertEq(q.lastSettled, ls);
        assertEq(q.tileCount, tc);
        assertEq(q.score, sc);
        assertEq(q.spawnTile, sp);
        assertEq(PP.id(PP.pack(p)), id);
    }

    function test_settleAccrues() public pure {
        PP.P memory p;
        p.grainRate = 5;
        p.oreRate = 2;
        p.lastSettled = 100;
        p.grain = 10;
        PP.settle(p, 110);
        assertEq(p.grain, 60);
        assertEq(p.ore, 20);
        assertEq(p.lastSettled, 110);
        // idempotent at same block
        PP.settle(p, 110);
        assertEq(p.grain, 60);
    }

    function test_settleSaturates() public pure {
        PP.P memory p;
        p.grainRate = type(uint16).max;
        p.lastSettled = 0;
        PP.settle(p, type(uint32).max);
        assertEq(p.grain, type(uint40).max);
    }

    // ---------------------------------------------------------------- HexGrid

    function test_adjacencyEvenRow() public pure {
        uint32 w = 10;
        uint32 h = 10;
        // tile (4,4): even row -> neighbours (5,4) (3,4) (3,3) (4,3) (3,5) (4,5)
        uint32 c = HexGrid.toId(4, 4, w);
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(5, 4, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(3, 4, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(3, 3, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(4, 3, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(3, 5, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(4, 5, w), w, h));
        assertFalse(HexGrid.isAdjacent(c, HexGrid.toId(5, 3, w), w, h));
        assertFalse(HexGrid.isAdjacent(c, HexGrid.toId(5, 5, w), w, h));
        assertFalse(HexGrid.isAdjacent(c, c, w, h));
    }

    function test_adjacencyOddRow() public pure {
        uint32 w = 10;
        uint32 h = 10;
        // tile (4,5): odd row -> neighbours (5,5) (3,5) (4,4) (5,4) (4,6) (5,6)
        uint32 c = HexGrid.toId(4, 5, w);
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(5, 5, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(3, 5, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(4, 4, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(5, 4, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(4, 6, w), w, h));
        assertTrue(HexGrid.isAdjacent(c, HexGrid.toId(5, 6, w), w, h));
        assertFalse(HexGrid.isAdjacent(c, HexGrid.toId(3, 4, w), w, h));
        assertFalse(HexGrid.isAdjacent(c, HexGrid.toId(3, 6, w), w, h));
    }

    function test_noWrapAroundEdges() public pure {
        uint32 w = 10;
        uint32 h = 10;
        // (9,0) and (0,1) are consecutive ids but not neighbours
        assertFalse(HexGrid.isAdjacent(HexGrid.toId(9, 0, w), HexGrid.toId(0, 1, w), w, h));
        // out of bounds is never adjacent
        assertFalse(HexGrid.isAdjacent(0, 100, w, h));
    }

    function testFuzz_neighborsSymmetric(uint8 x, uint8 y) public pure {
        uint32 w = 16;
        uint32 h = 16;
        x = uint8(bound(x, 0, 15));
        y = uint8(bound(y, 0, 15));
        uint32 id = HexGrid.toId(x, y, w);
        (uint32[6] memory ns, uint256 n) = HexGrid.neighbors(id, w, h);
        assertLe(n, 6);
        for (uint256 i = 0; i < n; i++) {
            assertTrue(HexGrid.isAdjacent(id, ns[i], w, h));
            assertTrue(HexGrid.isAdjacent(ns[i], id, w, h));
        }
    }

    // ---------------------------------------------------------------- Terrain

    function test_terrainDistribution() public pure {
        bytes32 seed = keccak256("season-1");
        uint256[4] memory counts;
        for (uint32 y = 0; y < 60; y++) {
            for (uint32 x = 0; x < 60; x++) {
                counts[Terrain.at(seed, x, y)]++;
            }
        }
        uint256 total = 3600;
        // Loose sanity bounds on the mix.
        assertGt(counts[Terrain.PLAINS], total * 35 / 100);
        assertGt(counts[Terrain.FOREST], total * 12 / 100);
        assertGt(counts[Terrain.HILLS], total * 5 / 100);
        assertGt(counts[Terrain.WATER], total * 3 / 100);
        assertLt(counts[Terrain.WATER], total * 25 / 100);
    }

    function test_terrainDeterministic() public pure {
        bytes32 seed = keccak256("x");
        assertEq(Terrain.at(seed, 7, 9), Terrain.at(seed, 7, 9));
        // A different seed should change at least one tile in a 20x20 block (overwhelmingly likely).
        bool differs;
        for (uint32 y = 0; y < 20 && !differs; y++) {
            for (uint32 x = 0; x < 20; x++) {
                if (Terrain.at(seed, x, y) != Terrain.at(keccak256("y"), x, y)) {
                    differs = true;
                    break;
                }
            }
        }
        assertTrue(differs);
    }

    // ---------------------------------------------------------------- SSTORE2

    function testFuzz_sstore2RoundTrip(bytes memory data) public {
        vm.assume(data.length <= 24_575);
        address p = SSTORE2.write(data);
        assertEq(SSTORE2.read(p), data);
        assertEq(SSTORE2.size(p), data.length);
    }

    function test_sstore2MaxSize() public {
        bytes memory data = new bytes(24_575);
        data[0] = 0xAA;
        data[24_574] = 0xBB;
        address p = SSTORE2.write(data);
        assertEq(SSTORE2.read(p), data);
    }

    function test_sstore2TooLarge() public {
        bytes memory data = new bytes(24_576);
        vm.expectRevert(SSTORE2.TooLarge.selector);
        this.writeExt(data);
    }

    function writeExt(bytes memory d) external returns (address) {
        return SSTORE2.write(d);
    }
}
