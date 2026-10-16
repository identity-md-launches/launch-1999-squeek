// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Squeek (SQK)
/// @notice A fixed-supply ERC-20 token. The whole supply of 1,000,000,000 SQK (18 decimals) is
///         minted once, in the constructor, to the deployer (`msg.sender`). Nothing can mint
///         afterwards, there is no owner, and no privileged function can pause, freeze, block or
///         seize a holder's balance. Transfers are plain: no fee, no tax, no burn on transfer.
/// @dev The deployer is the launch factory, which then pays the supply out: the swarm's share to
///      the launch's MerkleDistributor, the pool share to the Uniswap v4 PoolManager, and the
///      remainder to the requester. Because transfers are exact, none of those flows arrives short.
///      The contract name `SqueekToken` is the launch identifier (at most 32 characters); the token's
///      `name()` and `symbol()` are "Squeek" and "SQK".
contract SqueekToken is ERC20 {
    /// @notice The ERC-20 name.
    string public constant TOKEN_NAME = "Squeek";

    /// @notice The ERC-20 symbol.
    string public constant TOKEN_SYMBOL = "SQK";

    /// @notice Decimals of the token, as `decimals()` reports.
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply, in minor units: 1,000,000,000 * 10^18.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints the whole supply once to the deployer.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
