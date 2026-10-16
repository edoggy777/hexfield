# Hexfield

A fully onchain hex-territory strategy game for Base. No server, no indexer, no admin keys.
The rules, the map, every player's state **and the web page itself** are contracts.

```
src/
  World.sol            one season: spawn / move / recruit / build, lazy time, deterministic combat
  Renderer.sol         ERC-5219 static file server — the frontend, served over web3://
  SeasonRegistry.sol   permissionless factory + append-only index of seasons
  libs/
    TilePacking.sol    1 storage word per tile
    PlayerPacking.sol  1 storage word per player, lazy resource accrual
    HexGrid.sol        odd-r offset hex coordinates, adjacency, neighbours
    Terrain.sol        deterministic terrain from (seed, x, y) — never stored
    SSTORE2.sol        bytecode-as-storage for the UI chunks
client/                zero-dependency canvas client (14 KB total)
scripts/chunk.js       splits client/ into ≤24 KB chunks for upload
script/Deploy.s.sol    deploys registry + creates a season
script/DeployUI.s.sol  deploys Renderer, uploads the client, freezes it
test/                  50 tests incl. fuzzed conservation invariants; GasTest prints per-action gas
```

## How it works

**Lazy time.** Nothing ticks. A player's resources are `stored + rate × (block.number − lastSettled)`,
computed on read and settled on their next write. The world advances only when someone acts, and idle
costs nothing.

**One word per tile, one per player.** Terrain is a pure function of the season seed, so it is recomputed
(≈300 gas) rather than stored. A move touches exactly two storage slots.

**Deterministic combat.** Defender strength = garrison × terrain (hills 1.5×, forest 1.25×) × fort (2×),
rounded up. The attacker wins strictly when `n > strength` and keeps `n − strength` troops. On a repel every
attacker dies and the defender loses `n / multiplier`. No randomness, so no oracle and no griefable RNG.

**Seasons are deployments.** A `World` has immutable parameters and no owner. A new season is a new
contract created through `SeasonRegistry.create(...)`, which anyone can call. Clients default to
`registry.current()`.

**The UI lives in the Renderer.** Files are SSTORE2 chunks; `request(path)` returns them with headers,
per ERC-5219, which web3:// gateways (ERC-4804) understand. `/config.json` is generated from the
Renderer's immutables so one build can be pointed at any World. After `freeze()` nobody can change it;
a new UI version is a new Renderer, and old ones remain addressable forever — free "time travel".

## Gas (measured, warm state, excluding ~22k tx base)

| action                | gas    |
|-----------------------|--------|
| spawn                 | 78k    |
| move → claim empty    | 52k    |
| move → attack/capture | 28k    |
| move → attack/repel   | 30k    |
| move → merge own      | 11k    |
| recruit               | 23k    |
| build                 | 18k    |
| UI upload (14 KB)     | 4.8M once |

At Base fees that is a fraction of a cent per action.

## Build & test

```sh
forge install foundry-rs/forge-std   # if lib/forge-std is missing
forge build
forge test
forge test --match-contract GasTest -vv     # per-action gas
```

## Deploy (Base Sepolia first)

```sh
# 1. season
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --account <keystore>
#    env overrides: WIDTH HEIGHT SEED START_IN DURATION SPAWN_GARRISON START_GRAIN REGISTRY

# 2. UI
node scripts/chunk.js
WORLD=0x... forge script script/DeployUI.s.sol --rpc-url base_sepolia --broadcast --account <keystore>
#    NO_FREEZE=1 to keep iterating on testnet; RENDERER=0x... to re-upload into an unfrozen one
```

The script prints a `web3://<renderer>:<chainid>/` URL. Open it through a web3:// gateway
(e.g. `https://<renderer-address>.<chainid>.w3link.io/`) or a browser with web3:// support, or set a
Basename/ENS contenthash to the Renderer.

## Base App / Farcaster mini app

Mini apps need an HTTPS origin for the manifest. Point a domain at the gateway (or at an IPFS mirror of
the same `client/` build) and serve `miniapp/farcaster.json.template` (filled in) at
`/.well-known/farcaster.json`. The page still talks only to the chain; the domain is a pointer.

## Local development

```sh
anvil &
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key> START_IN=1
# serve client/ with any static server and drop a config.json beside it:
#   {"world":"0x...","chainId":31337}
```
(The client uses `http://127.0.0.1:8545` for chain id 31337.)

## Roadmap (v2)

- **Session keys / paymaster** via Base Account so a player signs once per session, not per move.
- **Fog of war** — commit–reveal moves, or a ZK membership proof per region.
- **Build time** for buildings (currently instant).
- **Client-side terrain**: the client can derive terrain from the public seed with keccak in JS, cutting
  `getRegion` cost by ~80% for very large maps.
- **Leaderboard view** — iterate `playerAddress(1..playerCount)` and `scoreOf`.

## Design constraints kept throughout

No custody, no matching of buyers and sellers, no prize pool, no token, no admin keys after deployment.
