// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {World} from "../src/World.sol";
import {TilePacking as T} from "../src/libs/TilePacking.sol";
import {HexGrid} from "../src/libs/HexGrid.sol";
import {Terrain} from "../src/libs/Terrain.sol";

/// Gas of each user action in a warm, realistic state (players already exist, tiles already touched).
/// Run: forge test --match-contract GasTest -vv   (or `forge snapshot`)
contract GasTest is Test {
    World w;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint32 a;
    uint32 b;
    uint32 c;

    function setUp() public {
        vm.roll(100);
        w = new World(32, 32, keccak256("gas"), 100, 1_000_000, 10, 1000);
        // find a land tile with two land neighbours
        for (uint32 i = 0; i < 32 * 32; i++) {
            if (!Terrain.isLand(w.terrainAt(i))) continue;
            (uint32[6] memory ns, uint256 n) = HexGrid.neighbors(i, 32, 32);
            uint32[2] memory found;
            uint256 k;
            for (uint256 j = 0; j < n && k < 2; j++) {
                if (Terrain.isLand(w.terrainAt(ns[j]))) found[k++] = ns[j];
            }
            if (k == 2) {
                a = i;
                b = found[0];
                c = found[1];
                break;
            }
        }
        vm.prank(alice);
        w.spawn(a);
        vm.prank(bob);
        w.spawn(b);
        vm.roll(200);
    }

    function test_gas_spawn() public {
        address carol = makeAddr("carol");
        uint32 t;
        for (t = 32 * 16; t < 32 * 32; t++) {
            if (Terrain.isLand(w.terrainAt(t))) break;
        }
        vm.prank(carol);
        uint256 g = gasleft();
        w.spawn(t);
        emit log_named_uint("spawn", g - gasleft());
    }

    function test_gas_moveClaim() public {
        vm.prank(alice);
        uint256 g = gasleft();
        w.move(a, c, 3);
        emit log_named_uint("move (claim empty tile)", g - gasleft());
    }

    function test_gas_moveMerge() public {
        vm.prank(alice);
        w.move(a, c, 3);
        vm.prank(alice);
        uint256 g = gasleft();
        w.move(a, c, 2);
        emit log_named_uint("move (merge own tile)", g - gasleft());
    }

    function test_gas_attackRepelled() public {
        vm.prank(alice);
        uint256 g = gasleft();
        w.move(a, b, 5);
        emit log_named_uint("move (attack, repelled)", g - gasleft());
    }

    function test_gas_attackCapture() public {
        vm.prank(alice);
        w.recruit(a, 40);
        vm.prank(alice);
        uint256 g = gasleft();
        w.move(a, b, 40);
        emit log_named_uint("move (attack, capture)", g - gasleft());
    }

    function test_gas_recruit() public {
        vm.prank(alice);
        uint256 g = gasleft();
        w.recruit(a, 5);
        emit log_named_uint("recruit", g - gasleft());
    }

    function test_gas_buildFarmOrFort() public {
        uint8 t = w.terrainAt(a);
        vm.prank(alice);
        uint256 g = gasleft();
        if (t == Terrain.HILLS) {
            w.build(a, T.B_MINE);
            emit log_named_uint("build (mine)", g - gasleft());
        } else {
            w.build(a, T.B_FARM);
            emit log_named_uint("build (farm)", g - gasleft());
        }
    }

    function test_gas_getRegionViewport() public {
        uint256 g = gasleft();
        w.getRegion(0, 0, 32, 20);
        emit log_named_uint("getRegion 32x20 (eth_call, free to caller)", g - gasleft());
    }
}
