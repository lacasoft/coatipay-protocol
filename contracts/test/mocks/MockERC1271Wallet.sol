// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

/// @title  MockERC1271Wallet
/// @notice Minimal ERC-1271 smart-contract wallet for tests. Returns the
///         0x1626ba7e magic value when `signature` is a valid ECDSA signature
///         by `owner` over `hash` — modeling how a smart wallet (e.g. Coinbase
///         Smart Wallet) delegates signature verification to its owner key.
contract MockERC1271Wallet {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 65) return INVALID;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        address recovered = ecrecover(hash, v, r, s);
        return (recovered != address(0) && recovered == owner) ? MAGIC : INVALID;
    }
}
