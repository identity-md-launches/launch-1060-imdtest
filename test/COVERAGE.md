# IMDT test coverage

Run `forge build` and `forge test` from the repository root. All Solidity
dependencies are already vendored; these tests need no RPC, environment
variables, filesystem permissions, or additional configuration.

- `IMDTToken.t.sol` checks constructor allocation, metadata, ERC-20 events and
  edge cases, fixed supply, rejected administrative calls, and forbidden runtime
  opcodes. Administrative probes use valid calldata and funded callers;
  `burnFrom` probes have allowance so missing authorization cannot hide a burn.
- `IMDTTokenAdversarial.t.sol` covers spender identity, revoking infinite
  approval, delegated self-transfers, finite approval at `uint256.max - 1`,
  zero-value delegated transfers, zero-source rejection, recipients that reject
  callbacks, and retrying an overdraw after adding exactly the missing unit.
- `SupplyInvariant.t.sol` retains the existing conservation campaign over
  transfers, delegated spending, and rejected overspends.
- `AllowanceInvariant.t.sol` keeps an independent model of every actor's balance
  and every owner/spender allowance. Separate approval, revocation, transfer,
  and delegated transfer actions run in random order, including zero and
  maximum amounts, self-transfers, invalid recipients, and invalid spenders.
  Rejected actions must preserve the whole model. It uses 256 sequences of
  96 actions with `fail-on-revert` enabled; expected token reverts are caught,
  while handler assertion failures fail the campaign.
- `LaunchFlow.t.sol` exercises the vendored v4 PoolManager locally at the
  supplied mainnet address with chain ID 1. Its 1,000-case fuzz property varies
  buy sizes from 1 gwei to 1 ether of IMD minor units and token currency order,
  then sells the entire bought balance. Both currencies must settle exactly.
  Existing launch checks cover the external 10% allocation, the 90% pool
  budget, rounding remainder, static fee, and atomic failed settlement.

All six fuzz properties specify 1,000 runs in their Solidity source so the
settings survive the verifier's plain `forge test` invocation.

## Scope and conflicting requirements

The mandatory launch requirements explicitly specify pool fee `3000` (0.30%),
while the earlier narrative requests `12500` (1.25%). Pool tests follow the
mandatory `3000` value; they do not claim that the pool charges 1.25%. The token
itself charges no transfer fee.

Pool parameters in these tests are fixtures copied from the mandatory brief.
The tests cannot read `launch.json` with the repository's existing filesystem
permissions and do not claim to validate that file at runtime.

The pool integration runs real vendored PoolManager code with a local IMD
balance fixture and test factory/trader drivers. Swarm distribution tests
model transfers from an external distributor, not Merkle proof verification.
No production factory, initialization guard, or Merkle distributor is included
in this project's source. A live mainnet fork and an end-to-end launch with
those external contracts remain outside this offline suite's coverage.
