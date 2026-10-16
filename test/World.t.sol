// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {World} from "../src/World.sol";
import {TilePacking as T} from "../src/libs/TilePacking.sol";
import {HexGrid} from "../src/libs/HexGrid.sol";
import {Terrain} from "../src/libs/Terrain.sol";

contract WorldTest is Test {
    World w;
    uint32 constant W = 24;
    uint32 constant H = 24;
    bytes32 constant SEED = keccak256("test-season");
    uint64 constant START = 100;
    uint64 constant END = 100_000;
    uint32 constant SPAWN = 10;
    uint40 constant GRAIN0 = 50;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.roll(START);
        w = new World(W, H, SEED, START, END, SPAWN, GRAIN0);
    }

    // ---------------------------------------------------------------- helpers

    function land(uint32 id) internal view returns (bool) {
        return Terrain.isLand(w.terrainAt(id));
    }

    /// first land tile at or after `from`
    function findLand(uint32 from) internal view returns (uint32) {
        for (uint32 i = from; i < W * H; i++) {
            if (land(i)) return i;
        }
        revert("no land");
    }

    /// first land tile of a given terrain at or after `from`
    function findTerrain(uint32 from, uint8 t) internal view returns (uint32) {
        for (uint32 i = from; i < W * H; i++) {
            if (w.terrainAt(i) == t) return i;
        }
        revert("no such terrain");
    }

    /// an unowned land neighbour of `id`
    function adjLand(uint32 id) internal view returns (uint32) {
        (uint32[6] memory ns, uint256 n) = HexGrid.neighbors(id, W, H);
        for (uint256 i = 0; i < n; i++) {
            (uint24 o,,,) = w.tile(ns[i]);
            if (land(ns[i]) && o == 0) return ns[i];
        }
        revert("no adjacent land");
    }

    /// a land tile with at least one land neighbour
    function findLandWithNeighbor(uint32 from) internal view returns (uint32 a, uint32 b) {
        for (uint32 i = from; i < W * H; i++) {
            if (!land(i)) continue;
            (uint32[6] memory ns, uint256 n) = HexGrid.neighbors(i, W, H);
            for (uint256 k = 0; k < n; k++) {
                if (land(ns[k])) return (i, ns[k]);
            }
        }
        revert("none");
    }

    function garrison(uint32 id) internal view returns (uint32 g) {
        (,, g,) = w.tile(id);
    }

    function ownerOf(uint32 id) internal view returns (uint24 o) {
        (o,,,) = w.tile(id);
    }

    function grainOf(address a) internal view returns (uint256 g) {
        (, g,,,,,,) = w.player(a);
    }

    function oreOf(address a) internal view returns (uint256 o) {
        (,, o,,,,,) = w.player(a);
    }

    function scoreOf(address a) internal view returns (uint24 s) {
        (,,,,,, s,) = w.player(a);
    }

    function tilesOf(address a) internal view returns (uint16 t) {
        (,,,,, t,,) = w.player(a);
    }

    // ---------------------------------------------------------------- spawn

    function test_spawn() public {
        uint32 t = findLand(0);
        vm.prank(alice);
        w.spawn(t);
        (uint24 id, uint256 grain, uint256 ore,,, uint16 tc, uint24 sc, uint32 sp) = w.player(alice);
        assertEq(id, 1);
        assertEq(grain, GRAIN0);
        assertEq(ore, 0);
        assertEq(tc, 1);
        assertEq(sc, 1);
        assertEq(sp, t);
        assertEq(ownerOf(t), 1);
        assertEq(garrison(t), SPAWN);
        assertEq(w.playerAddress(1), alice);
        assertEq(w.playerCount(), 1);
    }

    function test_spawnRevertsOnWater() public {
        uint32 t = findTerrain(0, Terrain.WATER);
        vm.prank(alice);
        vm.expectRevert(World.NotLand.selector);
        w.spawn(t);
    }

    function test_spawnRevertsTwice() public {
        uint32 t = findLand(0);
        uint32 t2 = findLand(t + 1);
        vm.startPrank(alice);
        w.spawn(t);
        vm.expectRevert(World.AlreadySpawned.selector);
        w.spawn(t2);
        vm.stopPrank();
    }

    function test_spawnRevertsOccupied() public {
        uint32 t = findLand(0);
        vm.prank(alice);
        w.spawn(t);
        vm.prank(bob);
        vm.expectRevert(World.TileOccupied.selector);
        w.spawn(t);
    }

    function test_spawnRevertsOutOfBounds() public {
        vm.prank(alice);
        vm.expectRevert(World.BadTile.selector);
        w.spawn(W * H);
    }

    // ---------------------------------------------------------------- lazy accrual

    function test_grainAccruesLazily() public {
        uint32 t = findTerrain(0, Terrain.PLAINS); // 2 grain / block
        vm.prank(alice);
        w.spawn(t);
        assertEq(grainOf(alice), GRAIN0);
        vm.roll(START + 10);
        assertEq(grainOf(alice), GRAIN0 + 20);
        // the stored value only changes on a write
        assertEq(w.playerRaw(alice) >> 24 & ((1 << 40) - 1), GRAIN0);
        vm.prank(alice);
        w.recruit(t, 1); // settles, spends 10
        assertEq(grainOf(alice), GRAIN0 + 20 - 10);
    }

    // ---------------------------------------------------------------- move

    function test_moveClaims() public {
        (uint32 a, uint32 b) = findLandWithNeighbor(0);
        vm.startPrank(alice);
        w.spawn(a);
        w.move(a, b, 4);
        vm.stopPrank();
        assertEq(garrison(a), SPAWN - 4);
        assertEq(garrison(b), 4);
        assertEq(ownerOf(b), 1);
        assertEq(tilesOf(alice), 2);
        assertEq(scoreOf(alice), 2);
    }

    function test_moveMerges() public {
        (uint32 a, uint32 b) = findLandWithNeighbor(0);
        vm.startPrank(alice);
        w.spawn(a);
        w.move(a, b, 4);
        w.move(a, b, 3);
        vm.stopPrank();
        assertEq(garrison(b), 7);
        assertEq(garrison(a), 3);
        assertEq(tilesOf(alice), 2);
    }

    function test_moveRevertsNotAdjacent() public {
        uint32 a = findLand(0);
        uint32 far = findLand(a + W * 3);
        vm.startPrank(alice);
        w.spawn(a);
        vm.expectRevert(World.NotAdjacent.selector);
        w.move(a, far, 1);
        vm.stopPrank();
    }

    function test_moveRevertsTooMany() public {
        (uint32 a, uint32 b) = findLandWithNeighbor(0);
        vm.startPrank(alice);
        w.spawn(a);
        vm.expectRevert(World.NotEnoughTroops.selector);
        w.move(a, b, SPAWN + 1);
        vm.stopPrank();
    }

    function test_moveRevertsNotOwner() public {
        (uint32 a, uint32 b) = findLandWithNeighbor(0);
        uint32 far = findLand(a + W * 5);
        vm.prank(alice);
        w.spawn(a);
        vm.prank(bob);
        w.spawn(far);
        vm.prank(bob);
        vm.expectRevert(World.NotOwner.selector);
        w.move(a, b, 1);
    }

    // ---------------------------------------------------------------- combat

    /// Set up alice on `a` and bob on adjacent `b`, with bob's tile on a known terrain if possible.
    function _twoPlayersAdjacent() internal returns (uint32 a, uint32 b) {
        (a, b) = findLandWithNeighbor(0);
        vm.prank(alice);
        w.spawn(a);
        vm.prank(bob);
        w.spawn(b);
    }

    function test_attackRepelled() public {
        (uint32 a, uint32 b) = _twoPlayersAdjacent();
        uint256 bps = Terrain.defenseBps(w.terrainAt(b));
        // bob has 10 troops; 10 * bps/1e4 >= 10, so attacking with 10 cannot win
        vm.prank(alice);
        w.move(a, b, 10);
        assertEq(ownerOf(b), 2, "bob keeps tile");
        assertEq(garrison(a), 0, "attackers left");
        uint256 expectedLoss = 10 * 10000 / bps;
        assertEq(garrison(b), 10 - expectedLoss, "defender losses");
        assertEq(tilesOf(alice), 1);
        assertEq(tilesOf(bob), 1);
    }

    function test_attackCaptures() public {
        (uint32 a, uint32 b) = _twoPlayersAdjacent();
        uint256 bps = Terrain.defenseBps(w.terrainAt(b));
        uint256 dEff = (10 * bps + 9999) / 10000;

        // give alice enough grain to recruit a big army
        vm.roll(START + 2000);
        vm.startPrank(alice);
        uint32 n = uint32(dEff + 5);
        w.recruit(a, n);
        w.move(a, b, n);
        vm.stopPrank();

        assertEq(ownerOf(b), 1, "alice took tile");
        assertEq(garrison(b), 5, "survivors");
        assertEq(tilesOf(alice), 2);
        assertEq(tilesOf(bob), 0);
        assertEq(scoreOf(bob), 0);
        assertEq(scoreOf(alice), 2);
    }

    function test_fortDoublesDefense() public {
        (uint32 a, uint32 b) = _twoPlayersAdjacent();
        // bob builds a fort: needs 20 ore. Only hills yield ore, so give him a mine route if hills,
        // otherwise skip (fort path is covered by the deterministic check below regardless).
        uint8 tb = w.terrainAt(b);
        if (tb != Terrain.HILLS) {
            // Use vm.store to grant ore directly: ore occupies bits 64..103 of the player word.
            uint256 word = w.playerRaw(bob);
            word |= uint256(20) << 64;
            vm.store(address(w), _playerSlot(bob), bytes32(word));
        } else {
            vm.roll(START + 100); // 1 ore/block on hills
        }
        vm.prank(bob);
        w.build(b, T.B_FORT);

        uint256 bps = Terrain.defenseBps(tb) * 2;
        uint256 dEff = (10 * bps + 9999) / 10000;

        vm.roll(START + 5000);
        vm.startPrank(alice);
        w.recruit(a, uint32(dEff));
        w.move(a, b, uint32(dEff)); // exactly equal -> repelled
        vm.stopPrank();
        assertEq(ownerOf(b), 2);
    }

    function _playerSlot(address a) internal pure returns (bytes32) {
        // _players is the 2nd declared storage var: slot 1 (slot 0 = _tiles mapping)
        return keccak256(abi.encode(a, uint256(1)));
    }

    function test_captureEmptyEnemyTile() public {
        (uint32 a, uint32 b) = _twoPlayersAdjacent();
        // bob moves everything off b onto a neighbour, leaving b owned but empty
        uint32 c = adjLand(b);
        vm.prank(bob);
        w.move(b, c, 10);
        assertEq(garrison(b), 0);
        assertEq(ownerOf(b), 2);
        vm.prank(alice);
        w.move(a, b, 1);
        assertEq(ownerOf(b), 1);
        assertEq(garrison(b), 1);
        assertEq(tilesOf(bob), 1);
    }

    // ---------------------------------------------------------------- build / recruit

    function test_buildFarmRaisesRate() public {
        uint32 t = findTerrain(0, Terrain.PLAINS);
        vm.startPrank(alice);
        w.spawn(t);
        (,,, uint16 gr0,,,,) = w.player(alice);
        w.build(t, T.B_FARM);
        (, uint256 grain,, uint16 gr1,,, uint24 sc,) = w.player(alice);
        vm.stopPrank();
        assertEq(gr1, gr0 + w.FARM_YIELD_GRAIN());
        assertEq(grain, GRAIN0 - w.FARM_COST_GRAIN());
        assertEq(sc, 3);
        (, uint8 b,,) = w.tile(t);
        assertEq(b, T.B_FARM);
    }

    function test_buildMineNeedsHills() public {
        uint32 t = findTerrain(0, Terrain.PLAINS);
        vm.startPrank(alice);
        w.spawn(t);
        vm.expectRevert(World.WrongTerrain.selector);
        w.build(t, T.B_MINE);
        vm.stopPrank();
    }

    function test_buildTwiceReverts() public {
        uint32 t = findTerrain(0, Terrain.PLAINS);
        vm.startPrank(alice);
        w.spawn(t);
        w.build(t, T.B_FARM);
        vm.expectRevert(World.AlreadyBuilt.selector);
        w.build(t, T.B_FARM);
        vm.stopPrank();
    }

    function test_recruitSpendsGrain() public {
        uint32 t = findLand(0);
        vm.startPrank(alice);
        w.spawn(t);
        w.recruit(t, 5);
        vm.stopPrank();
        assertEq(garrison(t), SPAWN + 5);
        assertEq(grainOf(alice), GRAIN0 - 50);
    }

    function test_recruitRevertsBroke() public {
        uint32 t = findLand(0);
        vm.startPrank(alice);
        w.spawn(t);
        vm.expectRevert(World.NotEnoughGrain.selector);
        w.recruit(t, 6);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- season bounds

    function test_beforeStartReverts() public {
        uint32 t = findLand(0);
        vm.roll(START - 1);
        vm.prank(alice);
        vm.expectRevert(World.SeasonNotStarted.selector);
        w.spawn(t);
    }

    function test_afterEndReverts() public {
        uint32 t = findLand(0);
        vm.prank(alice);
        w.spawn(t);
        vm.roll(END + 1);
        vm.prank(alice);
        vm.expectRevert(World.SeasonOver.selector);
        w.recruit(t, 1);
        assertFalse(w.isActive());
        // reads still work after the season
        assertEq(scoreOf(alice), 1);
    }

    // ---------------------------------------------------------------- views

    function test_getRegionEncodesTerrainAndBounds() public {
        uint32 t = findLand(0);
        vm.prank(alice);
        w.spawn(t);
        uint256[] memory r = w.getRegion(0, 0, W, 2);
        assertEq(r.length, W * 2);
        for (uint32 i = 0; i < W * 2; i++) {
            uint8 terrain = uint8((r[i] >> 64) & 0xF);
            assertEq(terrain, w.terrainAt(i));
            assertEq(T.owner(r[i]), i == t ? 1 : 0);
        }
        // out of bounds marker
        uint256[] memory edge = w.getRegion(W - 1, H - 1, 2, 2);
        assertEq(edge[1], type(uint256).max);
        assertEq(edge[2], type(uint256).max);
        assertEq(edge[3], type(uint256).max);
        assertTrue(edge[0] != type(uint256).max);
    }

    // ---------------------------------------------------------------- invariants (fuzzed sequences)

    /// Random sequences of valid moves between two players must never create troops out of thin air
    /// (total troops on the board + recruits spent == spawned + recruited), never leave a tile with two
    /// owners (trivially true with one owner field) and keep tileCount in sync with the board.
    function testFuzz_conservation(uint256 seedRand, uint8 steps) public {
        steps = uint8(bound(steps, 1, 24));
        _twoPlayersAdjacent();
        uint256 recruited;
        uint256 rng = seedRand;
        address[2] memory ps = [alice, bob];

        for (uint256 s = 0; s < steps; s++) {
            rng = uint256(keccak256(abi.encode(rng)));
            address p = ps[rng & 1];
            uint256 action = (rng >> 8) % 3;
            vm.roll(block.number + ((rng >> 16) % 50) + 1);
            (uint24 pid,,,,,,,) = w.player(p);

            if (action == 0) {
                // recruit on an owned tile
                uint32 t = _anyOwnedTile(pid);
                if (t == type(uint32).max) continue;
                uint32 n = uint32((rng >> 32) % 5) + 1;
                uint256 cost = n * w.RECRUIT_COST_GRAIN();
                if (grainOf(p) < cost) continue;
                vm.prank(p);
                w.recruit(t, n);
                recruited += n;
            } else {
                // move from an owned tile to a random land neighbour
                uint32 t = _anyOwnedTile(pid);
                if (t == type(uint32).max) continue;
                uint32 g = garrison(t);
                if (g == 0) continue;
                (uint32[6] memory ns, uint256 nn) = HexGrid.neighbors(t, W, H);
                uint32 to = ns[(rng >> 40) % nn];
                if (!land(to)) continue;
                uint32 n = uint32((rng >> 48) % g) + 1;
                vm.prank(p);
                w.move(t, to, n);
            }
            // board total never exceeds what was ever created
            assertLe(_boardTroops(), 2 * SPAWN + recruited);
            // tileCounts match the board
            assertEq(tilesOf(alice), _countOwned(1));
            assertEq(tilesOf(bob), _countOwned(2));
        }
    }

    function _anyOwnedTile(uint24 pid) internal view returns (uint32) {
        for (uint32 i = 0; i < W * H; i++) {
            if (ownerOf(i) == pid) return i;
        }
        return type(uint32).max;
    }

    function _boardTroops() internal view returns (uint256 total) {
        for (uint32 i = 0; i < W * H; i++) {
            total += garrison(i);
        }
    }

    function _countOwned(uint24 pid) internal view returns (uint16 c) {
        for (uint32 i = 0; i < W * H; i++) {
            if (ownerOf(i) == pid) c++;
        }
    }
}
