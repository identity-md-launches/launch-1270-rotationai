# RotationAI test suite

Run from the repository root:

```sh
forge build
forge test
```

The suite requires no RPC, environment variables, FFI, remappings, or dependency
installation. All dependency imports resolve to ordinary files in `test/vendor/`.
The project still uses the existing Solidity 0.8.26 / Cancun configuration.

## Coverage

- `RAIToken.t.sol`: deployment supply and branding, single mint event, one exact
  900,000,000-token seed transfer, factory/distributor allocation flows, tax routing
  and rounding, source-based `transferFrom` taxes, gross allowance spending,
  approval replacement/revocation, zero/self/overlapping-recipient transfers,
  maximum reachable tax, failed transfers and allowance rollback, absent admin
  selectors, and forbidden runtime opcodes. Fuzz tests use Foundry's default runs.
- `RAIInvariant.t.sol`: a bounded handler exercises transfers, buys, sells,
  approvals, delegated spending, rejected transfers, and forbidden admin calls.
  A separate ledger checks every tracked balance and allowance, fixed supply,
  and fixed parameters after each action. Includes the deployer, PoolManager,
  creator, distributor, and two wallets. Runs 64 sequences of 64 actions;
  unexpected handler reverts fail the test.
- `RAIPoolManager.t.sol`: deploys released Uniswap v4-core bytecode **at the
  required PoolManager address**, running its constructor in place to preserve
  the immutable address guard. Initializes native ETH / RAI at the 1 ETH opening
  market cap, with fee 12500 and tick spacing 60. Adds single-sided RAI liquidity,
  buys and sells with real LP fees, checks exact-input/exact-output accounting,
  forwards actual net router receipts, collects fees, and withdraws liquidity.
  Deliberate one-unit underpayments and an impossible minimum net output must
  revert atomically, including reverting tax, price, fee growth, and balances.
- `RAIPoolInvariant.t.sol`: 64 sequences of 32 randomized buys, sells, and LP fee
  collections. Checks native and token conservation, creator tax, unchanged LP
  fee, and zero outstanding PoolManager currency deltas after each action.

## Integration boundaries

The constructor must mint the entire supply to its deployer. The factory, not the
token, performs the 10% swarm transfer and 90% seed. The direct transfer test checks
the exact 900,000,000-token transfer. Real v4 liquidity uses integer liquidity
units: the integration test checks a single seed payment, an untaxed receipt,
and that the actual seed plus the factory's rounding remainder exactly equals
the 90% budget. The remainder uses the address specified in the assignment.

The actual opening price uses currency order (native ETH sorts before RAI),
rather than applying the manifest's opposite-order provenance price literally.
Pool fee configuration belongs to the factory/PoolManager, not to the ERC-20.

The test helpers model the factory's transfer/settlement steps and a trader's
callback; they are not production contracts or a Merkle distributor implementation.
No token balances are injected with storage edits. Only native test funding and
construction of the local PoolManager use cheatcodes that set chain state.

The offline tests do not verify Robinhood Chain's live PoolManager code/state,
the deployed launch factory, its initialization hook, its Merkle proofs, or an
external router. Live deployment and fork checks remain owed. See
`vendor/README.md` for pinned dependencies and licenses.
