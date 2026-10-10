# RotationAI ($RAI)

`src/RAIToken.sol` is a self-contained ERC-20 token compiled with Solidity 0.8.26 for Cancun. It has no constructor arguments, external dependencies, owner, administration, upgrade mechanism, or external calls.

The constructor mints exactly **1,000,000,000 RAI with 18 decimals (1e27 units)** to its caller. Supply cannot increase or decrease. The launch factory subsequently transfers 10% to its Merkle distributor and seeds the pool with 90% in an untaxed transfer. The token itself performs neither allocation.

Transfers **from** `0x8366a39CC670B4001A1121B8F6A443A643e40951` to another address pay a fixed 3% tax to `0xD85D2A13bD490a21959F1EcABe8aC82221D253bc`. The buyer receives the remainder. Tax rounds down to the nearest token minor unit. The source loses exactly the gross amount; `transferFrom` spends gross allowance. Transfers to the PoolManager, including a self-transfer, and ordinary wallet transfers are untaxed. A transfer to the tax recipient credits its total gross amount across the tax and net legs.

`launch.json` specifies the requested native-ETH pool, 1.25% pool fee, tick spacing 60, 1 ETH initial market cap, and 90% pool allocation. These are launch factory settings; an ERC-20 cannot configure the pool fee. The initial price field is provenance, with the actual opening price derived by the factory from economics and deployed currency order.

## Local checks

```sh
forge build
forge test
python3 scripts/check_artwork.py
```

Tests need no network or downloaded libraries. They cover complete factory/distributor transfers, seed and buy/sell balance accounting, tax events and rounding, direct and approved transfers, gross and infinite allowances, rollback on failure, self-transfers, zero amounts, recipient overlap, supply conservation, forbidden opcode scanning, and absent admin/mint/burn selectors. Two fuzz tests each use 1,000 runs; the sequence test checks conservation after each of 64 transfers.

These local token tests do not execute a real Uniswap v4 PoolManager or live Robinhood Chain fork. The supplied protected integration harness depends on verifier-owned factory helpers and launch environment values, which are not supplied as project dependencies. Its live pool initialization, liquidity seed, and swap checks remain for the verifier; the local suite checks the gross-in/net-out token accounting they depend on.

The five generated logo options are documented in `logos/README.md`. The selected wallet mark is `artifacts/logo.png`.
