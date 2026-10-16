// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SeasonRegistry} from "../src/SeasonRegistry.sol";
import {World} from "../src/World.sol";

/// Deploys (or reuses) the SeasonRegistry and creates a season.
///
/// env:
///   REGISTRY        optional existing registry address (deploys a new one if unset)
///   WIDTH, HEIGHT   map size            (default 48 x 48)
///   SEED            bytes32             (default keccak of the current block + sender)
///   START_IN        blocks from now until the season opens  (default 50)
///   DURATION        season length in blocks                 (default 604800 ≈ 14 days at 2s)
///   SPAWN_GARRISON  (default 10)   START_GRAIN (default 50)
///
///   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --account <keystore>
contract Deploy is Script {
    function run() external {
        uint32 width = uint32(vm.envOr("WIDTH", uint256(48)));
        uint32 height = uint32(vm.envOr("HEIGHT", uint256(48)));
        uint64 startIn = uint64(vm.envOr("START_IN", uint256(50)));
        uint64 duration = uint64(vm.envOr("DURATION", uint256(604_800)));
        uint32 spawnGarrison = uint32(vm.envOr("SPAWN_GARRISON", uint256(10)));
        uint40 startGrain = uint40(vm.envOr("START_GRAIN", uint256(50)));
        bytes32 seed =
            vm.envOr("SEED", keccak256(abi.encodePacked(block.number, msg.sender, block.timestamp)));
        address registryAddr = vm.envOr("REGISTRY", address(0));

        vm.startBroadcast();
        SeasonRegistry reg = registryAddr == address(0) ? new SeasonRegistry() : SeasonRegistry(registryAddr);
        uint64 startBlock = uint64(block.number) + startIn;
        address world =
            reg.create(width, height, seed, startBlock, startBlock + duration, spawnGarrison, startGrain);
        vm.stopBroadcast();

        console.log("SeasonRegistry:", address(reg));
        console.log("World:         ", world);
        console.log("start block:   ", startBlock);
        console.log("end block:     ", startBlock + duration);
        console.log("seed:");
        console.logBytes32(seed);
        console.log("");
        console.log("next: WORLD=%s forge script script/DeployUI.s.sol --broadcast ...", world);
    }
}
