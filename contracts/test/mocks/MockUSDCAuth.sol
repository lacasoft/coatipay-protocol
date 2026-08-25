// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @dev MockUSDC with ERC-3009 (`receiveWithAuthorization` /
///      `transferWithAuthorization`) support, mirroring Centre USDC v2.x
///      on Base. Used to test SettlementHub.payIntentWithAuthorization
///      and the batch variant. Implements a minimal but spec-compliant
///      ERC-3009 so signatures generated with Foundry's `vm.sign` against
///      the standard typehashes are accepted.
///
///      Implements both ERC-3009 functions (receive + transfer variants)
///      so the mock matches the real USDC interface even though
///      SettlementHub only uses `receiveWithAuthorization`.
contract MockUSDCAuth is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    /// @dev authorizer → nonce → consumed?
    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;

    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error InvalidSigner();
    error CallerMustBeReceiver();

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USD Coin")),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balances[from] >= amount, "insufficient balance");
        require(allowances[from][msg.sender] >= amount, "insufficient allowance");
        balances[from] -= amount;
        balances[to] += amount;
        allowances[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    // ── ERC-3009 ─────────────────────────────────────────────────

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    /// @notice Receive a transfer with a signed authorization. Enforces
    ///         msg.sender == to (this is the security-relevant difference
    ///         vs. transferWithAuthorization).
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
    ) external {
        if (msg.sender != to) revert CallerMustBeReceiver();
        _executeAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, v, r, s
        );
    }

    /// @notice Receive variant taking a raw `bytes` signature (FiatTokenV2_2).
    ///         Validates via a SignatureChecker-equivalent: ERC-1271 if `from`
    ///         is a contract, ECDSA otherwise. This is the path SettlementHub
    ///         uses post-Phase-1 (supports EOA + smart wallets).
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        if (msg.sender != to) revert CallerMustBeReceiver();
        _executeAuthorizationSig(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    /// @notice Transfer with a signed authorization. NO msg.sender check —
    ///         intentionally to match Centre USDC behavior. SettlementHub
    ///         does NOT use this (chose receive variant for front-running
    ///         protection — see ADR-003 §2.1.1). Provided for spec
    ///         completeness so mock matches real USDC interface.
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
    ) external {
        _executeAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, v, r, s
        );
    }

    function _executeAuthorization(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (_authorizationStates[from][nonce]) revert AuthorizationAlreadyUsed();

        bytes32 structHash = keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != from) revert InvalidSigner();

        _authorizationStates[from][nonce] = true;

        require(balances[from] >= value, "insufficient balance");
        balances[from] -= value;
        balances[to] += value;
    }

    /// @dev `bytes`-signature variant. Mirrors the timing/nonce checks of the
    ///      (v, r, s) path, then validates via `_isValidSignature` (ECDSA or
    ///      ERC-1271) like Circle's FiatTokenV2_2 SignatureChecker.
    function _executeAuthorizationSig(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) internal {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (_authorizationStates[from][nonce]) revert AuthorizationAlreadyUsed();

        bytes32 structHash = keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (!_isValidSignature(from, digest, signature)) revert InvalidSigner();

        _authorizationStates[from][nonce] = true;

        require(balances[from] >= value, "insufficient balance");
        balances[from] -= value;
        balances[to] += value;
    }

    /// @dev SignatureChecker-equivalent: if `signer` has code → ERC-1271
    ///      (`isValidSignature` must return the 0x1626ba7e magic value);
    ///      otherwise ECDSA recover from a 65-byte signature.
    function _isValidSignature(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        if (signer.code.length > 0) {
            (bool ok, bytes memory ret) =
                signer.staticcall(abi.encodeWithSelector(bytes4(0x1626ba7e), digest, signature));
            return ok && ret.length == 32 && abi.decode(ret, (bytes4)) == bytes4(0x1626ba7e);
        }
        if (signature.length != 65) return false;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        address recovered = ecrecover(digest, v, r, s);
        return recovered != address(0) && recovered == signer;
    }
}
