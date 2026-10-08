# IMDTEST (IMDT)

`src/IMDTToken.sol` is the only production contract. It inherits the unmodified
OpenZeppelin Contracts 5.0.2 ERC-20 implementation and mints exactly
**1,000,000,000 IMDT with 18 decimals (10^27 minor units)** to `msg.sender`
in its argument-free constructor. When the launch factory creates the token,
the factory receives the entire supply, not the transaction's originator.

There is no owner, administrator, initializer, upgrade mechanism, mint or burn
entry point, tax, dividend, transfer hook, pause, blacklist or configurable
parameter. Transfers and approvals follow standard ERC-20 behavior, including
zero-value transfers, rejection of the zero recipient, and non-decrementing
maximum allowances. No external calls occur during token transfers. Tokens sent
to the token contract cannot be rescued.

## Build and check offline

Install Foundry with Solidity **0.8.26** available in its compiler cache. All
Solidity dependencies needed by this project are ordinary files under `lib/`;
there is no dependency installation step or submodule. Python 3.11+ is needed
only for the additional manifest check.

```sh
forge build
forge test
forge fmt --check
python3 tools/check_launch.py
```

The root `foundry.toml` pins Solidity 0.8.26, Cancun, optimizer runs 200, via-IR
and `bytecode_hash = "none"`. FFI and Foundry filesystem permissions are disabled.
Tests do not use environment variables, RPC endpoints, keys or broadcasts.
The compiler executable is supplied by the build environment, not this repository.

## Launch parameters and the fee conflict

`launch.json` is the deployment input, with kind `custom_token`, no constructor
arguments and no application contracts. It deliberately has **no `chainId` key**;
Ethereum mainnet (chain ID 1) is an operational requirement, not a manifest field.

| Parameter | Required value |
| --- | --- |
| Pair currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Existing PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Static pool LP fee | `3000` |
| Tick spacing | `60` |
| Provenance sqrtPriceX96 | `125270724187523965593206900` |
| `economics.poolBps` | `9000` |
| `economics.initialMarketCapWei` | `"2500000000000000000000"` (2500 IMD) |
| `economics.remainderTo` | `0x000000000000000000000000000000000000dead` |

The mandatory build requirements explicitly fix `fee: 3000`; that value takes
precedence over the earlier conflicting request for 1.25%. Uniswap fee units are
hundredths of a basis point: **3000 means 0.30%**, while 12500 would mean 1.25%
(125 basis points). See the [Uniswap pool creation documentation](https://developers.uniswap.org/docs/protocols/v4/guides/create-pool).
`poolBps` uses ordinary basis points, with denominator 10,000. The token itself
charges no fee. The static LP fee does not remove Uniswap's own protocol-level
fee governance.

The supplied `initialPrice` records the integer square root of
`(initialMarketCapWei / totalSupply) * 2^192` with IMDT as currency0. It is
provenance only. The launch system must derive the actual price from the
economics and sorted deployed addresses; invert the ratio when IMDT is
currency1. The opening ratio is 0.0000025 IMD per IMDT.

## External factory responsibilities

The network's existing launch factory performs `ProjectFactory.launchCustom`.
No factory, distributor, hook or pool is deployed by this project's manifest.
Do not deploy the token directly from a wallet for a network launch: the direct
caller would receive every token, bypassing the factory's launch process.

1. Create `IMDTToken` using its compiled creation bytecode and no constructor
   arguments; verify the factory holds all 10^27 units.
2. Transfer **100,000,000 IMDT (10%)** to the network's Merkle distributor. The
   network determines recipients and proofs: 2% for accepted contributors and
   8% for paired seats. These recipients are not hardcoded in this project.
3. Initialize the sorted IMDT/IMD pool through the specified PoolManager using
   the mandatory fee, spacing and derived opening price, with the network's
   initialization guard. Seed single-sided liquidity with a budget of
   **900,000,000 IMDT (90% of total supply)** via the manager's unlock/settle flow.
   A plain transfer to PoolManager does not create liquidity.
4. Forward any unused balance, including liquidity rounding dust, to the exact
   supplied `remainderTo`. The dead address is explicitly requested, not an
   invented recipient. This transfer does not reduce `totalSupply()`.

Distribution and seeding happen after construction and are not enforced or
initiated by the token. The token never allocates 10% itself or mints a reduced
supply. Its parameters require no configuration after launch. Holders alone
control transfers and spender approvals; the former deployer has no privilege.

## Verification coverage and limits

The suite checks deployment supply and its recipient, events, ERC-20 allowances,
zero/self/full-balance transfers, insufficient funds, invalid recipients,
failed-call rollback, absence of admin entry points, and forbidden runtime
opcodes. Two fuzz tests each run 1,000 cases. A stateful invariant executes
128 sequences of 64 transfers, approvals/spends and rejected overspends, checking
that every unit remains accounted for and supply stays fixed.

Offline integration tests construct the vendored Uniswap v4 PoolManager at the
specified mainnet address on a local chain with ID 1. They cover both token
orders, single-sided seeding, exact settlement, a buy and full sell, fixed LP
fee, unauthorized callbacks and atomic rollback when a trader cannot pay.
The pair uses a test ERC-20 balance fixture at the specified IMD address. Swarm
claims model exact transfers from an external distributor account; they do not
implement or validate Merkle proofs. Test actors and their mint functions are
fixtures, excluded from `launch.json`.

These tests use a pool without hooks and do not certify the external factory,
initialization guard, live IMD behavior, Merkle distribution or current mainnet
state. The platform's pinned protected tests require its own factory support
contracts and launch environment; this project does not replace that validator.
Before release, the network deployer owns mainnet address/code verification,
full launch simulation with the actual guard/distributor, independent review,
deployment and explorer verification. No live fork, Slither or Mythril run is
claimed here, and no transaction has been broadcast.

`tools/check_launch.py` separately checks the exact manifest parameters and root
fields, compiler settings, built token ABI and vendored file hashes. It is a
local regression check, not a copy of the platform's admission schema.

## Dependency provenance

Only the transitive Solidity sources needed for the token and tests are included.
`lib/dependencies.json` records upstream repository URLs, exact commits and
SHA-256 hashes. Upstream license files and per-file notices are retained.

| Dependency | Pinned revision | Use |
| --- | --- | --- |
| OpenZeppelin Contracts 5.0.2 | `dbb6104ce834628e473d2173bbc9d47f81a9eec3` | Production ERC-20 |
| forge-std 1.9.6 | `3b20d60d14b343ee4f908cb8079495c07f5e8981` | Tests |
| Uniswap v4-core | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | Local integration tests |
| Solmate (v4 dependency) | `4b47a19038b798b4a33d9749d25e570443520647` | Local PoolManager only |
