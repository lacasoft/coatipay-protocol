// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

/// @title  IERC3009
/// @notice Minimal ERC-3009 interface ("Transfer With Authorization") as
///         implemented by Circle's USDC v2.x on Base mainnet/Sepolia.
/// @dev    SettlementHub uses receiveWithAuthorization (NOT
///         transferWithAuthorization) — see ADR-003 §2.1.1. The receive
///         variant enforces msg.sender == to, which prevents on-chain
///         front-running where an attacker submits a victim's signed
///         authorization to redirect funds or burn the nonce.
interface IERC3009 {
    /// @notice Receive a transfer with a signed authorization from the payer.
    /// @dev    USDC enforces msg.sender == to. Reverts if signature invalid,
    ///         expired, before validAfter, or if nonce already consumed.
    function receiveWithAuthorization(
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

    /// @notice Receive variant taking a raw `bytes` signature (FiatTokenV2_2).
    /// @dev    USDC validates via `SignatureChecker`, so this accepts BOTH
    ///         EOA ECDSA (65-byte) signatures AND ERC-1271 contract-wallet
    ///         signatures. This is the path that lets smart wallets (e.g.
    ///         Coinbase Smart Wallet) settle gaslessly — they cannot produce a
    ///         65-byte ecrecover signature. Same `msg.sender == to` and nonce
    ///         enforcement as the (v, r, s) overload.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;

    /// @notice Returns the state of a nonce for a given authorizer.
    /// @return true  if the nonce has been used (cannot be re-used)
    ///         false if the nonce is still available
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}
