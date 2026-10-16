// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SSTORE2 (minimal)
/// @notice Store a blob as the runtime bytecode of a throwaway contract (prefixed with STOP so it can
///         never be executed), and read it back with EXTCODECOPY. ~200 gas/byte to write vs ~20,000
///         per 32-byte SSTORE slot; reading is nearly free. Max 24,575 bytes per pointer.
library SSTORE2 {
    error WriteFailed();
    error TooLarge();

    uint256 internal constant MAX = 24_575;

    function write(bytes memory data) internal returns (address pointer) {
        if (data.length > MAX) revert TooLarge();
        // init code: 600B 59 81 38 03 80 92 59 39 F3  ==>  copies everything after the 11-byte
        // header into memory and returns it as the runtime code. The 00 is STOP.
        bytes memory code = abi.encodePacked(hex"600B5981380380925939F3", hex"00", data);
        assembly ("memory-safe") {
            pointer := create(0, add(code, 32), mload(code))
        }
        if (pointer == address(0)) revert WriteFailed();
    }

    function read(address pointer) internal view returns (bytes memory data) {
        assembly ("memory-safe") {
            let len := sub(extcodesize(pointer), 1)
            data := mload(0x40)
            mstore(0x40, add(data, and(add(add(len, 32), 31), not(31))))
            mstore(data, len)
            extcodecopy(pointer, add(data, 32), 1, len)
        }
    }

    function size(address pointer) internal view returns (uint256 s) {
        assembly ("memory-safe") {
            s := sub(extcodesize(pointer), 1)
        }
    }
}
