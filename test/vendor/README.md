# Offline PoolManager dependency

These ordinary source files are test dependencies, not contracts deployed by the launch.
Only the transitive imports needed by the integration tests are included; no submodules,
package installation, RPC, or remapping is needed.

- Uniswap **v4-core v4.0.0**, commit `e50237c43811bd9b526eff40f26772152a42daba`:
  https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba
- Solmate `Owned.sol`, at v4-core's pinned submodule commit
  `4b47a19038b798b4a33d9749d25e570443520647`:
  https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647

The only source change is `v4-core/src/ProtocolFees.sol`'s Solmate import, changed to
`../../solmate/src/auth/Owned.sol`. Solidity behavior is unchanged. Upstream SPDX
headers and license files are retained. The other imported Solidity files are verbatim.

This local released PoolManager exercises Cancun transient storage, unlock callbacks,
balance-difference settlements, real liquidity math, swaps, and LP fees. It does not
attest to the code or live state deployed on Robinhood Chain.
