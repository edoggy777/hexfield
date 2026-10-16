// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TilePacking as T} from "./libs/TilePacking.sol";
import {PlayerPacking as PP} from "./libs/PlayerPacking.sol";
import {HexGrid} from "./libs/HexGrid.sol";
import {Terrain} from "./libs/Terrain.sol";

/// @title World — one Hexfield season.
/// @notice Fully onchain hex territory game. No owner, no upgradeability, no off-chain components.
///         Time is lazy: nothing ticks on its own; resources accrue as a function of block.number and
///         are settled whenever a player acts. Combat is deterministic. One deployment == one season.
contract World {
    using PP for PP.P;

    // ------------------------------------------------------------------ config

    uint32 public immutable width;
    uint32 public immutable height;
    bytes32 public immutable seed;
    uint64 public immutable startBlock;
    uint64 public immutable endBlock;
    uint32 public immutable spawnGarrison;
    uint40 public immutable startGrain;

    uint256 public constant RECRUIT_COST_GRAIN = 10; // per troop
    uint256 public constant FARM_COST_GRAIN = 30;
    uint256 public constant MINE_COST_GRAIN = 30;
    uint256 public constant FORT_COST_ORE = 20;
    uint16 public constant FARM_YIELD_GRAIN = 3; // per block, added to the tile's base yield
    uint16 public constant MINE_YIELD_ORE = 3;
    uint256 public constant FORT_DEFENSE_BPS = 20000; // 2x

    // ------------------------------------------------------------------ state

    mapping(uint32 => uint256) internal _tiles;
    mapping(address => uint256) internal _players;
    mapping(uint24 => address) public playerAddress;
    uint24 public playerCount;

    // ------------------------------------------------------------------ events

    event Spawned(address indexed player, uint24 indexed id, uint32 tile);
    event TileChanged(uint32 indexed tile, uint256 packed);
    event Moved(address indexed player, uint32 indexed from, uint32 indexed to, uint32 troops, uint8 outcome);
    event Built(address indexed player, uint32 indexed tile, uint8 building);
    event Recruited(address indexed player, uint32 indexed tile, uint32 troops);

    /// outcome codes for Moved
    uint8 public constant OUT_CLAIM = 0;
    uint8 public constant OUT_MERGE = 1;
    uint8 public constant OUT_CAPTURE = 2;
    uint8 public constant OUT_REPELLED = 3;

    // ------------------------------------------------------------------ errors

    error SeasonOver();
    error SeasonNotStarted();
    error AlreadySpawned();
    error NotSpawned();
    error BadTile();
    error NotLand();
    error TileOccupied();
    error NotOwner();
    error NotAdjacent();
    error NotEnoughTroops();
    error NotEnoughGrain();
    error NotEnoughOre();
    error BadBuilding();
    error AlreadyBuilt();
    error WrongTerrain();
    error ZeroAmount();
    error Overflow();

    // ------------------------------------------------------------------ ctor

    constructor(
        uint32 width_,
        uint32 height_,
        bytes32 seed_,
        uint64 startBlock_,
        uint64 endBlock_,
        uint32 spawnGarrison_,
        uint40 startGrain_
    ) {
        require(width_ > 0 && height_ > 0 && uint256(width_) * height_ < type(uint32).max, "dims");
        require(endBlock_ > startBlock_, "blocks");
        width = width_;
        height = height_;
        seed = seed_;
        startBlock = startBlock_;
        endBlock = endBlock_;
        spawnGarrison = spawnGarrison_;
        startGrain = startGrain_;
    }

    modifier active() {
        if (block.number < startBlock) revert SeasonNotStarted();
        if (block.number > endBlock) revert SeasonOver();
        _;
    }

    // ------------------------------------------------------------------ actions

    /// @notice Enter the season on an unowned land tile.
    function spawn(uint32 tileId) external active {
        if (PP.id(_players[msg.sender]) != 0) revert AlreadySpawned();
        _requireTile(tileId);
        uint8 terrain = terrainAt(tileId);
        if (!Terrain.isLand(terrain)) revert NotLand();
        uint256 t = _tiles[tileId];
        if (T.owner(t) != 0) revert TileOccupied();

        uint24 id = ++playerCount;
        playerAddress[id] = msg.sender;

        (uint16 gy, uint16 oy) = Terrain.baseYield(terrain);
        PP.P memory p = PP.P({
            id: id,
            grain: startGrain,
            ore: 0,
            grainRate: gy,
            oreRate: oy,
            lastSettled: uint32(block.number),
            tileCount: 1,
            score: 1,
            spawnTile: tileId
        });
        _players[msg.sender] = PP.pack(p);

        t = T.pack(id, T.B_NONE, spawnGarrison);
        _tiles[tileId] = t;

        emit Spawned(msg.sender, id, tileId);
        emit TileChanged(tileId, t);
    }

    /// @notice Move `n` troops from an owned tile to an adjacent tile. Claims, merges or attacks.
    function move(uint32 from, uint32 to, uint32 n) external active {
        if (n == 0) revert ZeroAmount();
        if (!HexGrid.isAdjacent(from, to, width, height)) revert NotAdjacent();
        uint8 toTerrain = terrainAt(to);
        if (!Terrain.isLand(toTerrain)) revert NotLand();

        uint256 pw = _players[msg.sender];
        uint24 me = PP.id(pw);
        if (me == 0) revert NotSpawned();

        uint256 tf = _tiles[from];
        if (T.owner(tf) != me) revert NotOwner();
        uint32 g = T.garrison(tf);
        if (g < n) revert NotEnoughTroops();
        tf = T.setGarrison(tf, g - n);
        _tiles[from] = tf;
        emit TileChanged(from, tf);

        uint256 tt = _tiles[to];
        uint24 them = T.owner(tt);

        if (them == 0) {
            // claim
            PP.P memory p = PP.unpack(pw);
            p.settle(block.number);
            _gainTile(p, toTerrain, T.building(tt));
            _players[msg.sender] = PP.pack(p);
            tt = T.pack(me, T.building(tt), n);
            _tiles[to] = tt;
            emit TileChanged(to, tt);
            emit Moved(msg.sender, from, to, n, OUT_CLAIM);
            return;
        }

        if (them == me) {
            uint256 ng = uint256(T.garrison(tt)) + n;
            if (ng > T.GARRISON_MASK) revert Overflow();
            tt = T.setGarrison(tt, uint32(ng));
            _tiles[to] = tt;
            emit TileChanged(to, tt);
            emit Moved(msg.sender, from, to, n, OUT_MERGE);
            return;
        }

        uint8 outcome = _combat(to, toTerrain, tt, them, me, n);
        emit Moved(msg.sender, from, to, n, outcome);
    }

    /// @dev Deterministic combat. Defender effective strength = garrison * terrain * fort (ceil).
    ///      Attacker wins strictly when n > effective; survivors = n - effective.
    ///      On a repel, every attacker dies and the defender loses floor(n / multiplier).
    function _combat(uint32 to, uint8 toTerrain, uint256 tt, uint24 them, uint24 me, uint32 n)
        internal
        returns (uint8 outcome)
    {
        uint32 d = T.garrison(tt);
        uint8 b = T.building(tt);
        uint256 bps = Terrain.defenseBps(toTerrain);
        if (b == T.B_FORT) bps = bps * FORT_DEFENSE_BPS / 10000;
        uint256 dEff = (uint256(d) * bps + 9999) / 10000;

        if (n > dEff) {
            _transferTile(playerAddress[them], msg.sender, toTerrain, b);
            tt = T.pack(me, b, uint32(n - dEff));
            outcome = OUT_CAPTURE;
        } else {
            uint256 loss = uint256(n) * 10000 / bps;
            tt = T.setGarrison(tt, loss >= d ? 0 : uint32(d - loss));
            outcome = OUT_REPELLED;
        }
        _tiles[to] = tt;
        emit TileChanged(to, tt);
    }

    function _transferTile(address fromAddr, address toAddr, uint8 terrain, uint8 b) internal {
        PP.P memory loser = PP.unpack(_players[fromAddr]);
        loser.settle(block.number);
        _loseTile(loser, terrain, b);
        _players[fromAddr] = PP.pack(loser);

        PP.P memory winner = PP.unpack(_players[toAddr]);
        winner.settle(block.number);
        _gainTile(winner, terrain, b);
        _players[toAddr] = PP.pack(winner);
    }

    /// @notice Spend grain to add troops to an owned tile.
    function recruit(uint32 tileId, uint32 n) external active {
        if (n == 0) revert ZeroAmount();
        uint256 pw = _players[msg.sender];
        uint24 me = PP.id(pw);
        if (me == 0) revert NotSpawned();
        uint256 t = _tiles[tileId];
        if (T.owner(t) != me) revert NotOwner();

        PP.P memory p = PP.unpack(pw);
        p.settle(block.number);
        uint256 cost = uint256(n) * RECRUIT_COST_GRAIN;
        if (p.grain < cost) revert NotEnoughGrain();
        p.grain -= uint40(cost);
        _players[msg.sender] = PP.pack(p);

        uint256 ng = uint256(T.garrison(t)) + n;
        if (ng > T.GARRISON_MASK) revert Overflow();
        t = T.setGarrison(t, uint32(ng));
        _tiles[tileId] = t;
        emit TileChanged(tileId, t);
        emit Recruited(msg.sender, tileId, n);
    }

    /// @notice Build a farm (plains/forest, grain), mine (hills, grain) or fort (any land, ore).
    function build(uint32 tileId, uint8 bType) external active {
        uint256 pw = _players[msg.sender];
        uint24 me = PP.id(pw);
        if (me == 0) revert NotSpawned();
        uint256 t = _tiles[tileId];
        if (T.owner(t) != me) revert NotOwner();
        if (T.building(t) != T.B_NONE) revert AlreadyBuilt();
        uint8 terrain = terrainAt(tileId);

        PP.P memory p = PP.unpack(pw);
        p.settle(block.number);

        if (bType == T.B_FARM) {
            if (terrain != Terrain.PLAINS && terrain != Terrain.FOREST) revert WrongTerrain();
            if (p.grain < FARM_COST_GRAIN) revert NotEnoughGrain();
            p.grain -= uint40(FARM_COST_GRAIN);
            p.grainRate += FARM_YIELD_GRAIN;
            p.score += 2;
        } else if (bType == T.B_MINE) {
            if (terrain != Terrain.HILLS) revert WrongTerrain();
            if (p.grain < MINE_COST_GRAIN) revert NotEnoughGrain();
            p.grain -= uint40(MINE_COST_GRAIN);
            p.oreRate += MINE_YIELD_ORE;
            p.score += 2;
        } else if (bType == T.B_FORT) {
            if (p.ore < FORT_COST_ORE) revert NotEnoughOre();
            p.ore -= uint40(FORT_COST_ORE);
            p.score += 3;
        } else {
            revert BadBuilding();
        }

        _players[msg.sender] = PP.pack(p);
        t = T.setBuilding(t, bType);
        _tiles[tileId] = t;
        emit TileChanged(tileId, t);
        emit Built(msg.sender, tileId, bType);
    }

    // ------------------------------------------------------------------ internal accounting

    function _buildingYield(uint8 b) internal pure returns (uint16 grain, uint16 ore) {
        if (b == T.B_FARM) return (FARM_YIELD_GRAIN, 0);
        if (b == T.B_MINE) return (0, MINE_YIELD_ORE);
        return (0, 0);
    }

    function _buildingScore(uint8 b) internal pure returns (uint24) {
        if (b == T.B_FARM || b == T.B_MINE) return 2;
        if (b == T.B_FORT) return 3;
        return 0;
    }

    function _gainTile(PP.P memory p, uint8 terrain, uint8 b) internal pure {
        (uint16 g1, uint16 o1) = Terrain.baseYield(terrain);
        (uint16 g2, uint16 o2) = _buildingYield(b);
        p.grainRate += g1 + g2;
        p.oreRate += o1 + o2;
        p.tileCount += 1;
        p.score += 1 + _buildingScore(b);
    }

    function _loseTile(PP.P memory p, uint8 terrain, uint8 b) internal pure {
        (uint16 g1, uint16 o1) = Terrain.baseYield(terrain);
        (uint16 g2, uint16 o2) = _buildingYield(b);
        p.grainRate -= g1 + g2;
        p.oreRate -= o1 + o2;
        p.tileCount -= 1;
        p.score -= 1 + _buildingScore(b);
    }

    function _requireTile(uint32 tileId) internal view {
        if (!HexGrid.inBounds(tileId, width, height)) revert BadTile();
    }

    // ------------------------------------------------------------------ views

    function terrainAt(uint32 tileId) public view returns (uint8) {
        _requireTile(tileId);
        (uint32 x, uint32 y) = HexGrid.toXY(tileId, width);
        return Terrain.at(seed, x, y);
    }

    function tileRaw(uint32 tileId) external view returns (uint256) {
        return _tiles[tileId];
    }

    function tile(uint32 tileId)
        external
        view
        returns (uint24 owner, uint8 building, uint32 garrison, uint8 terrain)
    {
        uint256 t = _tiles[tileId];
        return (T.owner(t), T.building(t), T.garrison(t), terrainAt(tileId));
    }

    function playerRaw(address a) external view returns (uint256) {
        return _players[a];
    }

    /// @notice Player state with live (lazily accrued) balances.
    function player(address a)
        external
        view
        returns (
            uint24 id,
            uint256 grain,
            uint256 ore,
            uint16 grainRate,
            uint16 oreRate,
            uint16 tileCount,
            uint24 score,
            uint32 spawnTile
        )
    {
        PP.P memory p = PP.unpack(_players[a]);
        (grain, ore) = p.liveBalances(block.number);
        return (p.id, grain, ore, p.grainRate, p.oreRate, p.tileCount, p.score, p.spawnTile);
    }

    function scoreOf(address a) external view returns (uint24) {
        return PP.unpack(_players[a]).score;
    }

    /// @notice Batched viewport read: one eth_call per frame.
    /// @dev Each word is the tile's packed storage with terrain OR'd into bits 64..67.
    ///      Out-of-bounds cells are returned as type(uint256).max.
    function getRegion(uint32 x0, uint32 y0, uint32 w, uint32 h)
        external
        view
        returns (uint256[] memory out)
    {
        out = new uint256[](uint256(w) * h);
        uint256 k;
        for (uint32 dy = 0; dy < h; dy++) {
            uint32 y = y0 + dy;
            for (uint32 dx = 0; dx < w; dx++) {
                uint32 x = x0 + dx;
                if (x >= width || y >= height) {
                    out[k++] = type(uint256).max;
                    continue;
                }
                uint32 id = HexGrid.toId(x, y, width);
                out[k++] = _tiles[id] | (uint256(Terrain.at(seed, x, y)) << 64);
            }
        }
    }

    function config()
        external
        view
        returns (uint32, uint32, bytes32, uint64, uint64, uint32, uint40, uint24)
    {
        return (width, height, seed, startBlock, endBlock, spawnGarrison, startGrain, playerCount);
    }

    function isActive() external view returns (bool) {
        return block.number >= startBlock && block.number <= endBlock;
    }
}
