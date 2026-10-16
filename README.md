# Squeek (SQK)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Parameter        | Value                                                        |
| ---------------- | ------------------------------------------------------------ |
| Contract         | `SqueekToken` (`src/SqueekToken.sol`)                        |
| Name             | Squeek                                                       |
| Symbol           | SQK                                                          |
| Decimals         | 18                                                           |
| Total supply     | 1,000,000,000 SQK = `1000000000000000000000000000` minor units |
| Minted to        | `msg.sender` of the constructor, once, in the constructor    |
| Constructor args | none                                                         |
| Owner / admin    | none                                                         |

## What the token does

- Mints the whole supply of 1,000,000,000 SQK (18 decimals) to the deployer in the constructor.
- Standard ERC-20 transfers, approvals and `transferFrom`, from OpenZeppelin Contracts v5.2.0 `ERC20`.
- Nothing else. There is no mint function, no owner, no pause, no blocklist, no fee or tax on transfer,
  no burn on transfer, and no upgrade path. The supply can never grow after deployment.

## Assumptions

- The deployer is the launch factory. The constructor mints to `msg.sender`, so the factory holds the
  whole supply after deployment and pays it out: 10% to the launch's MerkleDistributor, 80% to seed the
  Uniswap v4 pool paired with IMD, and the remaining 10% to the requester's address from the launch
  economics. Because transfers are exact, every one of those flows arrives whole.
- The contract has no constructor arguments and calls no other contract, so it deploys on an empty
  chain and needs no configuration before or after launch.
- `SqueekToken` is the Solidity name the launch records (11 characters, under the 32 limit). The
  token's on-chain `name()` and `symbol()` are "Squeek" and "SQK".
- Holders can burn nothing through the contract (there is no burn function); the supply only moves.
- There is no `permit` (EIP-2612). The brief asked for a plain token, so none was added.

## Deployment parameters

- Compiler: solc 0.8.26, optimizer on with 200 runs, EVM version cancun, `bytecode_hash = "none"` and
  `cbor_metadata = false` so the built bytecode is reproducible without a metadata hash.
- Constructor arguments: none. The launch manifest's `token.constructorArgs` is an empty list and its
  `token.totalSupply` is `1000000000000000000000000000`.
- IMD's deployer launches the contract through the factory. Nothing in this repository deploys,
  broadcasts or holds keys, and no `launch.json` is written here.

## After launch

There is nothing to set. The token has no owner-settable values and no owner.

## Operational responsibilities

- Nobody can intervene in the token after deployment: no address can mint, pause, freeze, blocklist
  or seize. Anyone relying on the token should treat it as immutable.
- The holder of the supply right after deployment is the factory, which distributes it as the launch
  dictates. After that, each holder is solely responsible for its own keys and approvals. Approvals
  are standard ERC-20 approvals: an infinite approval stays infinite until revoked.
- Explorer verification of the deployed source belongs to the launch deployer, using this repository's
  pinned compiler settings.

## Security notes

Checked against the eth-security reference supplied with the task:

- No reentrancy surface: the token makes no external calls.
- No access control, because there is nothing privileged to control.
- No `delegatecall`, `callcode` or `selfdestruct` in the runtime (asserted by a test).
- No proxy or upgradeability.
- Tests passing are not an audit. The contract is a thin wrapper over OpenZeppelin's audited ERC20,
  and the launch's own protected checks run against the built bytecode before admission.

## Layout

```
foundry.toml          compiler pins and build settings
remappings.txt        forge-std and @openzeppelin/contracts remappings
src/SqueekToken.sol   the token
test/SqueekToken.t.sol  success, failure and fuzz tests
lib/forge-std         vendored forge-std v1.9.7 (plain files, no submodule)
lib/openzeppelin      vendored OpenZeppelin Contracts v5.2.0, token/utils/interfaces only
```

## Build and test

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables and pass in any order and in parallel.
