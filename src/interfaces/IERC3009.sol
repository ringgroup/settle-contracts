// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IERC3009
/// @notice Minimal interface for EIP-3009 `transferWithAuthorization`. Implemented by
///         USDC (and several other modern stablecoins) — lets a customer sign an
///         off-chain authorization that anyone can submit on-chain. Drainer-safe
///         because the authorization specifies exact `to` and `value` and is
///         single-use (consumed by `nonce`).
interface IERC3009 {
    /// @notice Transfer `value` tokens from `from` to `to` on behalf of `from`,
    ///         using a pre-signed authorization.
    /// @dev Reverts if the authorization is invalid, expired, not yet valid, or
    ///      the nonce has already been used.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
