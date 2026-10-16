// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Renderer} from "../src/Renderer.sol";

/// Deploys a Renderer for a World, uploads the chunked client from out/ui, and freezes it.
///
///   node scripts/chunk.js
///   WORLD=0x... forge script script/DeployUI.s.sol --rpc-url base_sepolia --broadcast --account <keystore>
///
/// env:
///   WORLD      the World this UI points at (required)
///   RENDERER   optional existing (unfrozen) Renderer to upload into instead of deploying a new one
///   NO_FREEZE  set to 1 to leave the renderer writable (for iterating on testnet)
contract DeployUI is Script {
    function run() external {
        address world = vm.envAddress("WORLD");
        address existing = vm.envOr("RENDERER", address(0));
        bool noFreeze = vm.envOr("NO_FREEZE", false);

        string memory list = vm.readFile("out/ui/files.txt");
        string[] memory lines = vm.split(list, "\n");

        vm.startBroadcast();
        Renderer r = existing == address(0) ? new Renderer(world, block.chainid) : Renderer(existing);

        uint256 uploaded;
        for (uint256 i = 0; i < lines.length; i++) {
            if (bytes(lines[i]).length == 0) continue;
            string[] memory f = vm.split(lines[i], "|");
            uint256 n = vm.parseUint(f[2]);
            bytes[] memory chunks = new bytes[](n);
            for (uint256 k = 0; k < n; k++) {
                chunks[k] =
                    vm.readFileBinary(string.concat("out/ui/", vm.toString(i), "_", vm.toString(k), ".bin"));
            }
            r.put(f[0], f[1], chunks);
            uploaded++;
            console.log("put %s (%s chunks)", f[0], n);
        }
        if (!noFreeze) r.freeze();
        vm.stopBroadcast();

        console.log("");
        console.log("Renderer:", address(r));
        console.log("files:   ", uploaded);
        console.log("frozen:  ", !noFreeze);
        console.log("");
        console.log("web3://%s:%s/", vm.toString(address(r)), vm.toString(block.chainid));
    }
}
