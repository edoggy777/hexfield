// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {World} from "./World.sol";

/// @title SeasonRegistry — permissionless factory + append-only index of seasons.
/// @notice Anyone can create a season; because the registry deploys the World itself, every entry is
///         guaranteed to be an unmodified World (immutables make codehash checks useless, so a factory
///         is the honest way to vouch for bytecode). No owner. Which season is "canonical" is a social
///         convention: clients default to `current()` and the frontend lists all of them.
contract SeasonRegistry {
    address[] public seasons;

    event SeasonCreated(
        uint256 indexed index,
        address indexed world,
        address indexed creator,
        uint64 startBlock,
        uint64 endBlock
    );

    function create(
        uint32 width,
        uint32 height,
        bytes32 seed,
        uint64 startBlock,
        uint64 endBlock,
        uint32 spawnGarrison,
        uint40 startGrain
    ) external returns (address world) {
        world = address(new World(width, height, seed, startBlock, endBlock, spawnGarrison, startGrain));
        uint256 index = seasons.length;
        seasons.push(world);
        emit SeasonCreated(index, world, msg.sender, startBlock, endBlock);
    }

    function count() external view returns (uint256) {
        return seasons.length;
    }

    function latest() external view returns (address) {
        return seasons.length == 0 ? address(0) : seasons[seasons.length - 1];
    }

    /// @notice The most recently created season that is currently active, or address(0).
    function current() external view returns (address) {
        for (uint256 i = seasons.length; i > 0; i--) {
            World w = World(seasons[i - 1]);
            if (block.number >= w.startBlock() && block.number <= w.endBlock()) return address(w);
        }
        return address(0);
    }

    function all() external view returns (address[] memory) {
        return seasons;
    }
}
