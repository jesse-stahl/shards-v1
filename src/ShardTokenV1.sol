// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ShardConstantsV1 } from "./ShardConstantsV1.sol";

/// @notice Fixed-supply fungible unit. 1e18 of it == 1 NFT.
/// @dev No mint, no burn, no owner. Supply is immutable from construction —
///      the hook's core invariant depends on it.
contract ShardTokenV1 is ERC20 {
    /// @param name_ ERC-20 name for this collection's unit. Supplied per launch, and bound into the
    ///        token's CREATE2 address through the factory's effective token salt — two launches that
    ///        differ only by name are different tokens at different addresses.
    /// @param symbol_ ERC-20 symbol, same binding.
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, ShardConstantsV1.MAX_NFTS * ShardConstantsV1.SHARDS_PER_NFT);
    }
}
