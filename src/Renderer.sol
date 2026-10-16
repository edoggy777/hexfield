// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SSTORE2} from "./libs/SSTORE2.sol";

/// @dev ERC-5219 / ERC-6944 "resource request" interface, as served over web3:// gateways.
///      web3://<this>.base.eth/index.html  ==>  request(["index.html"], [])
struct KeyValue {
    string key;
    string value;
}

interface IDecentralizedApp {
    function request(string[] memory resource, KeyValue[] memory params)
        external
        view
        returns (uint16 statusCode, string memory body, KeyValue[] memory headers);
}

/// @title Renderer — the game's frontend, served from chain state.
/// @notice A tiny static file server. Files are uploaded as SSTORE2 chunks by the publisher, then the
///         contract is frozen and nobody (including the publisher) can change it again. A new UI
///         version is a new Renderer; old versions stay addressable forever.
///
///         Gateways: web3:// (ERC-4804, mode "5219") — e.g. https://w3link.io, or a Basename/ENS
///         contenthash pointing here. `/config.json` is generated, not stored, so the same UI build can
///         be re-pointed at a new World by deploying a new Renderer with a different `world`.
contract Renderer is IDecentralizedApp {
    struct File {
        address[] chunks;
        string contentType;
        bool exists;
    }

    address public immutable world;
    uint256 public immutable chainId;
    address public publisher;
    bool public frozen;

    mapping(bytes32 => File) internal _files;
    string[] public paths;

    event FilePut(string path, uint256 size, uint256 chunks);
    event Frozen();

    error NotPublisher();
    error IsFrozen();
    error NotFound();

    constructor(address world_, uint256 chainId_) {
        world = world_;
        chainId = chainId_;
        publisher = msg.sender;
    }

    // ------------------------------------------------------------------ publishing

    modifier onlyPublisher() {
        if (msg.sender != publisher) revert NotPublisher();
        if (frozen) revert IsFrozen();
        _;
    }

    /// @notice Upload a file in one or more chunks (each ≤ 24,575 bytes). Replaces any existing file.
    function put(string calldata path, string calldata contentType, bytes[] calldata chunks)
        external
        onlyPublisher
    {
        bytes32 k = keccak256(bytes(path));
        File storage f = _files[k];
        if (!f.exists) {
            paths.push(path);
            f.exists = true;
        }
        delete f.chunks;
        uint256 total;
        for (uint256 i = 0; i < chunks.length; i++) {
            f.chunks.push(SSTORE2.write(chunks[i]));
            total += chunks[i].length;
        }
        f.contentType = contentType;
        emit FilePut(path, total, chunks.length);
    }

    /// @notice Append chunks to an existing file (for files larger than one tx comfortably carries).
    function append(string calldata path, bytes[] calldata chunks) external onlyPublisher {
        File storage f = _files[keccak256(bytes(path))];
        if (!f.exists) revert NotFound();
        for (uint256 i = 0; i < chunks.length; i++) {
            f.chunks.push(SSTORE2.write(chunks[i]));
        }
    }

    /// @notice Make the renderer immutable. Irreversible.
    function freeze() external onlyPublisher {
        frozen = true;
        publisher = address(0);
        emit Frozen();
    }

    // ------------------------------------------------------------------ serving

    /// @dev ERC-4804 resolve mode: tells gateways to use the ERC-5219 `request` interface.
    function resolveMode() external pure returns (bytes32) {
        return "5219";
    }

    function request(string[] memory resource, KeyValue[] memory)
        external
        view
        override
        returns (uint16, string memory, KeyValue[] memory)
    {
        string memory path = _join(resource);
        if (bytes(path).length == 0) path = "index.html";

        KeyValue[] memory headers = new KeyValue[](2);
        headers[1] = KeyValue("Cache-Control", "public, max-age=31536000, immutable");

        if (keccak256(bytes(path)) == keccak256("config.json")) {
            headers[0] = KeyValue("Content-Type", "application/json");
            headers[1] = KeyValue("Cache-Control", "no-cache");
            return (200, _configJson(), headers);
        }

        File storage f = _files[keccak256(bytes(path))];
        if (!f.exists) {
            headers[0] = KeyValue("Content-Type", "text/plain");
            return (404, "not found", headers);
        }
        headers[0] = KeyValue("Content-Type", f.contentType);
        return (200, string(_read(f)), headers);
    }

    /// @notice Raw file read (for non-gateway clients and tests).
    function file(string calldata path) external view returns (bytes memory data, string memory contentType) {
        File storage f = _files[keccak256(bytes(path))];
        if (!f.exists) revert NotFound();
        return (_read(f), f.contentType);
    }

    function fileCount() external view returns (uint256) {
        return paths.length;
    }

    function _read(File storage f) internal view returns (bytes memory out) {
        uint256 n = f.chunks.length;
        if (n == 1) return SSTORE2.read(f.chunks[0]);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += SSTORE2.size(f.chunks[i]);
        }
        out = new bytes(total);
        uint256 off;
        for (uint256 i = 0; i < n; i++) {
            bytes memory c = SSTORE2.read(f.chunks[i]);
            uint256 len = c.length;
            assembly ("memory-safe") {
                mcopy(add(add(out, 32), off), add(c, 32), len)
            }
            off += len;
        }
    }

    function _join(string[] memory parts) internal pure returns (string memory s) {
        for (uint256 i = 0; i < parts.length; i++) {
            s = i == 0 ? parts[i] : string.concat(s, "/", parts[i]);
        }
    }

    function _configJson() internal view returns (string memory) {
        return string.concat(
            '{"world":"',
            _hex(world),
            '","chainId":',
            _dec(chainId),
            ',"renderer":"',
            _hex(address(this)),
            '"}'
        );
    }

    function _hex(address a) internal pure returns (string memory) {
        bytes16 sym = "0123456789abcdef";
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 41; i > 1; i--) {
            s[i] = sym[v & 0xf];
            v >>= 4;
        }
        return string(s);
    }

    function _dec(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 n = v;
        uint256 len;
        while (n != 0) {
            len++;
            n /= 10;
        }
        bytes memory s = new bytes(len);
        while (v != 0) {
            s[--len] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(s);
    }
}
