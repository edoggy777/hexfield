// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Renderer, KeyValue} from "../src/Renderer.sol";
import {World} from "../src/World.sol";
import {SeasonRegistry} from "../src/SeasonRegistry.sol";

contract RendererTest is Test {
    Renderer r;
    address world = address(0xBEEF);

    function setUp() public {
        r = new Renderer(world, 8453);
    }

    function _one(bytes memory d) internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = d;
    }

    function test_putAndRequest() public {
        r.put("index.html", "text/html", _one("<h1>hi</h1>"));
        string[] memory res = new string[](1);
        res[0] = "index.html";
        (uint16 code, string memory body, KeyValue[] memory h) = r.request(res, new KeyValue[](0));
        assertEq(code, 200);
        assertEq(body, "<h1>hi</h1>");
        assertEq(h[0].key, "Content-Type");
        assertEq(h[0].value, "text/html");
        assertEq(r.fileCount(), 1);
    }

    function test_rootServesIndex() public {
        r.put("index.html", "text/html", _one("root"));
        (uint16 code, string memory body,) = r.request(new string[](0), new KeyValue[](0));
        assertEq(code, 200);
        assertEq(body, "root");
    }

    function test_nestedPath() public {
        r.put("assets/app.js", "text/javascript", _one("x=1"));
        string[] memory res = new string[](2);
        res[0] = "assets";
        res[1] = "app.js";
        (uint16 code, string memory body,) = r.request(res, new KeyValue[](0));
        assertEq(code, 200);
        assertEq(body, "x=1");
    }

    function test_notFound() public view {
        string[] memory res = new string[](1);
        res[0] = "nope";
        (uint16 code,,) = r.request(res, new KeyValue[](0));
        assertEq(code, 404);
    }

    function test_multiChunkReassembly() public {
        bytes memory a = new bytes(24_575);
        bytes memory b = new bytes(1000);
        for (uint256 i = 0; i < a.length; i++) {
            a[i] = bytes1(uint8(i));
        }
        for (uint256 i = 0; i < b.length; i++) {
            b[i] = bytes1(uint8(i) ^ 0xFF);
        }
        bytes[] memory c = new bytes[](2);
        c[0] = a;
        c[1] = b;
        r.put("big.bin", "application/octet-stream", c);
        (bytes memory data,) = r.file("big.bin");
        assertEq(data.length, a.length + b.length);
        assertEq(data, bytes.concat(a, b));
    }

    function test_appendExtendsFile() public {
        r.put("f", "text/plain", _one("ab"));
        r.append("f", _one("cd"));
        (bytes memory data,) = r.file("f");
        assertEq(string(data), "abcd");
    }

    function test_replaceFile() public {
        r.put("f", "text/plain", _one("old"));
        r.put("f", "text/plain", _one("new"));
        (bytes memory data,) = r.file("f");
        assertEq(string(data), "new");
        assertEq(r.fileCount(), 1);
    }

    function test_configJson() public view {
        string[] memory res = new string[](1);
        res[0] = "config.json";
        (uint16 code, string memory body, KeyValue[] memory h) = r.request(res, new KeyValue[](0));
        assertEq(code, 200);
        assertEq(h[0].value, "application/json");
        assertEq(
            body,
            string.concat(
                '{"world":"0x000000000000000000000000000000000000beef","chainId":8453,"renderer":"',
                _lowerHex(address(r)),
                '"}'
            )
        );
    }

    function test_freezeIsPermanent() public {
        r.put("f", "text/plain", _one("x"));
        r.freeze();
        assertTrue(r.frozen());
        assertEq(r.publisher(), address(0));
        vm.expectRevert(Renderer.NotPublisher.selector);
        r.put("f", "text/plain", _one("y"));
        (bytes memory data,) = r.file("f");
        assertEq(string(data), "x");
    }

    function test_onlyPublisherCanPut() public {
        vm.prank(address(0x1234));
        vm.expectRevert(Renderer.NotPublisher.selector);
        r.put("f", "text/plain", _one("x"));
    }

    function test_resolveMode() public view {
        assertEq(r.resolveMode(), bytes32("5219"));
    }

    // ---------------------------------------------------------------- registry

    function test_registryCreatesAndIndexes() public {
        vm.roll(10);
        SeasonRegistry reg = new SeasonRegistry();
        assertEq(reg.latest(), address(0));
        assertEq(reg.current(), address(0));

        address w1 = reg.create(8, 8, keccak256("a"), 10, 1000, 5, 20);
        assertEq(reg.latest(), w1);
        assertEq(reg.current(), w1);
        assertEq(World(w1).width(), 8);
        assertEq(World(w1).endBlock(), 1000);

        address w2 = reg.create(8, 8, keccak256("b"), 2000, 3000, 5, 20);
        assertEq(reg.latest(), w2);
        assertEq(reg.current(), w1, "w2 not started yet");
        vm.roll(2500);
        assertEq(reg.current(), w2);
        vm.roll(5000);
        assertEq(reg.current(), address(0));
        assertEq(reg.count(), 2);
        assertEq(reg.all().length, 2);
    }

    function _lowerHex(address a) internal pure returns (string memory) {
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
}
