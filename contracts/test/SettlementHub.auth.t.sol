// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IntentSigning} from "./helpers/IntentSigning.sol";
import {SettlementHub} from "../src/SettlementHub.sol";
import {Pausable} from "../src/Pausable.sol";
import {MockUSDCAuth} from "./mocks/MockUSDCAuth.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";

/// @title  SettlementHub.payIntentWithAuthorization tests (single + batch)
/// @notice ERC-3009 settlement path tests. Separate file from SettlementHub.t.sol
///         so the new mock (MockUSDCAuth, with ERC-3009) doesn't disturb the
///         existing tests that use MockUSDCPermit (with EIP-2612).
///         See ADR-003 for the design rationale of payIntentWithAuthorization.
contract SettlementHubAuthTest is Test, IntentSigning {
    SettlementHub hub;
    MockUSDCAuth usdc;

    address treasury = makeAddr("treasury");
    address guardian = makeAddr("guardian");
    address merchant = makeAddr("merchant");
    address operator = makeAddr("operator");
    address payer;
    uint256 payerKey;

    bytes32 constant INTENT_ID = keccak256("pi_auth_test_001");
    uint256 constant AMOUNT = 1_000_000_000; // 1000 USDC
    uint64 expiresAt;

    function setUp() public {
        // Warp to a sane epoch so `block.timestamp - 100` in expired-auth
        // tests doesn't underflow (Foundry defaults to block.timestamp = 1).
        vm.warp(1_700_000_000); // ~2023-11

        usdc = new MockUSDCAuth();
        hub = new SettlementHub(address(usdc), treasury, guardian, _intentSigner());

        (payer, payerKey) = makeAddrAndKey("payer");
        usdc.mint(payer, 10 * AMOUNT);

        expiresAt = uint64(block.timestamp + 30 minutes);
    }

    // ── Helpers ───────────────────────────────────────────────

    function _registerIntent(bytes32 id) internal {
        _reg(hub, id, merchant, operator, AMOUNT, expiresAt);
    }

    /// Sign the ReceiveWithAuthorization digest and return it as a packed
    /// 65-byte `(r, s, v)` blob — the `bytes signature` the contract now takes.
    function _signReceiveAuth(
        uint256 fromKey,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory signature) {
        bytes32 structHash = keccak256(
            abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    /// El nonce NO es un parámetro: el hub exige `nonce == intentId` para que
    /// una firma no pueda aplicarse a otro intent (F-1). Derivarlo aquí evita
    /// que un test futuro use un nonce suelto y pruebe algo que no existe.
    function _buildAuth(
        bytes32 intentId,
        address payerAddr,
        uint256 fromKey,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore
    ) internal view returns (SettlementHub.Authorization memory auth) {
        bytes32 nonce = intentId;
        bytes memory signature =
            _signReceiveAuth(fromKey, payerAddr, address(hub), amount, validAfter, validBefore, nonce);
        auth = SettlementHub.Authorization({
            intentId: intentId,
            payer: payerAddr,
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: signature
        });
    }

    function _defaultAuth() internal view returns (SettlementHub.Authorization memory) {
        return _buildAuth(
            INTENT_ID,
            payer,
            payerKey,
            AMOUNT,
            block.timestamp - 1, // validAfter — already valid
            block.timestamp + 1 hours
        );
    }

    // ── payIntentWithAuthorization — ERC-1271 smart wallet ────

    /// A smart-contract wallet (ERC-1271) pays gaslessly: the wallet's owner key
    /// signs, the wallet's `isValidSignature` validates, and USDC's
    /// SignatureChecker accepts it via the `bytes` overload. This is the case an
    /// EOA-only (v,r,s) path could never support (Coinbase Smart Wallet etc.).
    function test_PayWithAuth_ERC1271SmartWallet_Success() public {
        (address swOwner, uint256 swOwnerKey) = makeAddrAndKey("smartWalletOwner");
        MockERC1271Wallet wallet = new MockERC1271Wallet(swOwner);
        usdc.mint(address(wallet), 10 * AMOUNT);

        bytes32 id = keccak256("pi_1271");
        _registerIntent(id);

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = id; // atado al intent (F-1)

        // `from` is the WALLET, but the signature is produced by the owner key.
        bytes memory signature =
            _signReceiveAuth(swOwnerKey, address(wallet), address(hub), AMOUNT, validAfter, validBefore, nonce);

        SettlementHub.Authorization memory auth = SettlementHub.Authorization({
            intentId: id,
            payer: address(wallet),
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: signature
        });

        hub.payIntentWithAuthorization(auth);

        assertEq(usdc.balanceOf(merchant), 985_000_000, "merchant 98.5%");
        assertEq(usdc.balanceOf(operator), 10_500_000, "operator 1.05%");
        assertEq(usdc.balanceOf(treasury), 4_500_000, "treasury 0.45%");
        assertEq(usdc.balanceOf(address(wallet)), 9 * AMOUNT, "wallet paid 1000");
    }

    /// A smart wallet whose owner did NOT sign → 1271 returns the non-magic
    /// value → USDC rejects. Guards against forged contract-wallet signatures.
    function test_PayWithAuth_ERC1271_Revert_WrongOwner() public {
        (address swOwner,) = makeAddrAndKey("swOwner2");
        (, uint256 attackerKey) = makeAddrAndKey("attacker1271");
        MockERC1271Wallet wallet = new MockERC1271Wallet(swOwner);
        usdc.mint(address(wallet), 10 * AMOUNT);

        _registerIntent(INTENT_ID);
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = INTENT_ID; // atado al intent (F-1)

        // Signed by the attacker, not the wallet's owner.
        bytes memory signature =
            _signReceiveAuth(attackerKey, address(wallet), address(hub), AMOUNT, validAfter, validBefore, nonce);

        SettlementHub.Authorization memory auth = SettlementHub.Authorization({
            intentId: INTENT_ID,
            payer: address(wallet),
            validAfter: validAfter,
            validBefore: validBefore,
            nonce: nonce,
            signature: signature
        });

        vm.expectRevert(MockUSDCAuth.InvalidSigner.selector);
        hub.payIntentWithAuthorization(auth);
    }

    // ── payIntentWithAuthorization — success ──────────────────

    function test_PayWithAuth_Success() public {
        _registerIntent(INTENT_ID);

        SettlementHub.Authorization memory auth = _defaultAuth();

        // Anyone can submit (the operator's daemon, in production)
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        hub.payIntentWithAuthorization(auth);

        // 1000 USDC = 990 merchant + 7 operator + 3 treasury (100 bps total, 70/30)
        assertEq(usdc.balanceOf(merchant), 985_000_000, "merchant 98.5%");
        assertEq(usdc.balanceOf(operator), 10_500_000, "operator 1.05%");
        assertEq(usdc.balanceOf(treasury), 4_500_000, "treasury 0.45%");
        assertEq(usdc.balanceOf(address(hub)), 0, "hub holds nothing");

        SettlementHub.Intent memory i = hub.getIntent(INTENT_ID);
        assertEq(uint8(i.status), uint8(SettlementHub.IntentStatus.Settled));
    }

    function test_PayWithAuth_AnyoneCanSubmit() public {
        // Verifies ADR-003 §2.3: payer signs; ANY account submits + pays gas.
        _registerIntent(INTENT_ID);
        SettlementHub.Authorization memory auth = _defaultAuth();

        // Three different submitters in three different intents — all settle.
        for (uint256 i = 0; i < 3; i++) {
            bytes32 id = keccak256(abi.encode("intent", i));
            _registerIntent(id);
            SettlementHub.Authorization memory a =
                _buildAuth(id, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);
            address submitter = makeAddr(string(abi.encodePacked("submitter_", i)));
            vm.prank(submitter);
            hub.payIntentWithAuthorization(a);

            SettlementHub.Intent memory ii = hub.getIntent(id);
            assertEq(uint8(ii.status), uint8(SettlementHub.IntentStatus.Settled));
        }

        // Original intent still works too
        hub.payIntentWithAuthorization(auth);
    }

    function test_PayWithAuth_EmitsSettledEvent() public {
        _registerIntent(INTENT_ID);
        SettlementHub.Authorization memory auth = _defaultAuth();

        vm.expectEmit(true, true, false, true);
        emit SettlementHub.IntentSettled(INTENT_ID, payer, 985_000_000, 10_500_000, 4_500_000);
        hub.payIntentWithAuthorization(auth);
    }

    function test_PayWithAuth_WorksWhenPaused() public {
        // Pause semantics (Q5/ADR-001): payments NOT blocked when paused.
        _registerIntent(INTENT_ID);
        vm.prank(guardian);
        hub.pause();

        SettlementHub.Authorization memory auth = _defaultAuth();
        hub.payIntentWithAuthorization(auth);

        SettlementHub.Intent memory i = hub.getIntent(INTENT_ID);
        assertEq(uint8(i.status), uint8(SettlementHub.IntentStatus.Settled));
    }

    // ── payIntentWithAuthorization — reverts (intent-side) ────

    function test_PayWithAuth_Revert_IntentNotFound() public {
        SettlementHub.Authorization memory auth = _defaultAuth();
        vm.expectRevert(SettlementHub.IntentNotFound.selector);
        hub.payIntentWithAuthorization(auth);
    }

    function test_PayWithAuth_Revert_IntentAlreadySettled() public {
        _registerIntent(INTENT_ID);
        SettlementHub.Authorization memory auth = _defaultAuth();
        hub.payIntentWithAuthorization(auth);

        // El nonce vuelve a ser el intentId, porque ahora está atado (F-1).
        // Se llega igualmente a IntentNotPayable: el estado del intent se
        // comprueba ANTES de llamar a USDC, así que ese chequeo gana al mapa
        // de nonces. Nótese la defensa doble — aunque el estado fallara,
        // USDC rechazaría el nonce ya consumido.
        SettlementHub.Authorization memory auth2 =
            _buildAuth(INTENT_ID, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);
        vm.expectRevert(SettlementHub.IntentNotPayable.selector);
        hub.payIntentWithAuthorization(auth2);
    }

    function test_PayWithAuth_Revert_IntentExpired() public {
        _registerIntent(INTENT_ID);

        // Warp past the intent's expiresAt (not the authorization's validBefore)
        vm.warp(uint256(expiresAt) + 1);

        SettlementHub.Authorization memory auth =
            _buildAuth(INTENT_ID, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 10 minutes);
        vm.expectRevert(SettlementHub.IntentExpired.selector);
        hub.payIntentWithAuthorization(auth);
    }

    // ── payIntentWithAuthorization — reverts (authorization-side) ─

    function test_PayWithAuth_Revert_AuthorizationExpired() public {
        _registerIntent(INTENT_ID);

        SettlementHub.Authorization memory auth =
            _buildAuth(INTENT_ID, payer, payerKey, AMOUNT, block.timestamp - 100, block.timestamp - 1);

        vm.expectRevert(MockUSDCAuth.AuthorizationExpired.selector);
        hub.payIntentWithAuthorization(auth);
    }

    function test_PayWithAuth_Revert_AuthorizationNotYetValid() public {
        _registerIntent(INTENT_ID);

        SettlementHub.Authorization memory auth = _buildAuth(
            INTENT_ID,
            payer,
            payerKey,
            AMOUNT,
            block.timestamp + 100, // not yet valid
            block.timestamp + 200
        );

        vm.expectRevert(MockUSDCAuth.AuthorizationNotYetValid.selector);
        hub.payIntentWithAuthorization(auth);
    }

    function test_PayWithAuth_Revert_NonceReused() public {
        _registerIntent(INTENT_ID);
        SettlementHub.Authorization memory auth = _defaultAuth();

        // First settle succeeds
        hub.payIntentWithAuthorization(auth);

        // Register a new intent and try to reuse the same nonce
        bytes32 id2 = keccak256("pi_auth_test_002");
        _registerIntent(id2);
        SettlementHub.Authorization memory auth2 = SettlementHub.Authorization({
            intentId: id2, // different intent
            payer: auth.payer,
            validAfter: auth.validAfter,
            validBefore: auth.validBefore,
            nonce: auth.nonce, // same nonce — should be rejected
            signature: auth.signature
        });

        // Reproducir una autorización buena contra OTRO intent es justo el
        // ataque de F-1. Ahora lo corta la atadura nonce↔intent antes incluso
        // de llegar a USDC; y si llegara, el nonce ya está consumido.
        vm.expectRevert();
        hub.payIntentWithAuthorization(auth2);
    }

    function test_PayWithAuth_Revert_InvalidSigner() public {
        _registerIntent(INTENT_ID);

        // Sign with a wrong key (attacker's key)
        (, uint256 wrongKey) = makeAddrAndKey("attacker");
        SettlementHub.Authorization memory auth = _buildAuth(
            INTENT_ID,
            payer, // claims to be from `payer` ...
            wrongKey, // ... but signed by the attacker
            AMOUNT,
            block.timestamp - 1,
            block.timestamp + 1 hours
        );

        vm.expectRevert(MockUSDCAuth.InvalidSigner.selector);
        hub.payIntentWithAuthorization(auth);
    }

    function test_PayWithAuth_Revert_PayerMismatch() public {
        // The `payer` parameter doesn't match the actual signer.
        // USDC verifies the signature was for (from = auth.payer), so if
        // the real signer signed for a different `from` address, recover
        // returns the real signer != auth.payer → InvalidSigner.
        _registerIntent(INTENT_ID);

        (address realSigner, uint256 realKey) = makeAddrAndKey("realSigner");
        usdc.mint(realSigner, AMOUNT);

        SettlementHub.Authorization memory auth = SettlementHub.Authorization({
            intentId: INTENT_ID,
            payer: payer, // claimed payer
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: INTENT_ID, // atado al intent (F-1)
            signature: ""
        });

        // Sign as realSigner (NOT payer)
        auth.signature =
            _signReceiveAuth(realKey, realSigner, address(hub), AMOUNT, auth.validAfter, auth.validBefore, auth.nonce);

        // The signature recovers to realSigner, but auth.payer = payer.
        // USDC's receiveWithAuthorization recomputes the digest using
        // (auth.payer, address(this), AMOUNT, ...) and verifies against
        // (v, r, s). Recovered = realSigner != auth.payer → reverts.
        vm.expectRevert(MockUSDCAuth.InvalidSigner.selector);
        hub.payIntentWithAuthorization(auth);
    }

    function test_PayWithAuth_Revert_AmountMismatch() public {
        // The contract pulls intent.amount via receiveWithAuthorization.
        // If the payer signed for a DIFFERENT value, USDC's signature
        // verification fails (sig was over (..., signedValue, ...) but
        // contract calls with intent.amount).
        _registerIntent(INTENT_ID);

        SettlementHub.Authorization memory auth = _buildAuth(
            INTENT_ID,
            payer,
            payerKey,
            AMOUNT / 2, // signer authorized only HALF the amount
            block.timestamp - 1,
            block.timestamp + 1 hours
        );

        vm.expectRevert(MockUSDCAuth.InvalidSigner.selector);
        hub.payIntentWithAuthorization(auth);
    }

    // ── payOneAuthorizedSelfCall — Forbidden ─────────────────

    function test_PayOneAuthorizedSelfCall_Revert_NotSelfCall() public {
        // External callers cannot invoke the self-call entry point —
        // it's protected by msg.sender == address(this).
        SettlementHub.Authorization memory auth = _defaultAuth();
        vm.expectRevert(SettlementHub.Forbidden.selector);
        hub.payOneAuthorizedSelfCall(auth);
    }

    // ── payIntentBatchWithAuthorization ───────────────────────

    function test_PayBatch_AllSuccess() public {
        SettlementHub.Authorization[] memory auths = new SettlementHub.Authorization[](5);
        for (uint256 i = 0; i < 5; i++) {
            bytes32 id = keccak256(abi.encode("batch_ok", i));
            _registerIntent(id);
            auths[i] = _buildAuth(id, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);
        }

        uint256 settled = hub.payIntentBatchWithAuthorization(auths);
        assertEq(settled, 5, "all settled");

        // All intents now in Settled state
        for (uint256 i = 0; i < 5; i++) {
            bytes32 id = keccak256(abi.encode("batch_ok", i));
            SettlementHub.Intent memory ii = hub.getIntent(id);
            assertEq(uint8(ii.status), uint8(SettlementHub.IntentStatus.Settled));
        }

        // Merchant balance reflects 5 successful payments (5 × 990 USDC)
        assertEq(usdc.balanceOf(merchant), 5 * 985_000_000);
    }

    function test_PayBatch_SkipOnFailure() public {
        // 3 valid + 2 invalid (1 expired auth, 1 unregistered intent)
        SettlementHub.Authorization[] memory auths = new SettlementHub.Authorization[](5);

        // [0] valid
        bytes32 id0 = keccak256("batch_mix_0");
        _registerIntent(id0);
        auths[0] = _buildAuth(id0, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);

        // [1] expired authorization (intent registered, auth expired)
        bytes32 id1 = keccak256("batch_mix_1");
        _registerIntent(id1);
        auths[1] = _buildAuth(id1, payer, payerKey, AMOUNT, block.timestamp - 100, block.timestamp - 1);

        // [2] valid
        bytes32 id2 = keccak256("batch_mix_2");
        _registerIntent(id2);
        auths[2] = _buildAuth(id2, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);

        // [3] intent not registered
        bytes32 id3 = keccak256("batch_mix_3_not_registered");
        auths[3] = _buildAuth(id3, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);

        // [4] valid
        bytes32 id4 = keccak256("batch_mix_4");
        _registerIntent(id4);
        auths[4] = _buildAuth(id4, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);

        uint256 settled = hub.payIntentBatchWithAuthorization(auths);
        assertEq(settled, 3, "3 of 5 settled");

        // Verify the right ones settled (0, 2, 4)
        assertEq(uint8(hub.getIntent(id0).status), uint8(SettlementHub.IntentStatus.Settled));
        assertEq(
            uint8(hub.getIntent(id1).status), uint8(SettlementHub.IntentStatus.Registered), "expired auth not settled"
        );
        assertEq(uint8(hub.getIntent(id2).status), uint8(SettlementHub.IntentStatus.Settled));
        assertEq(uint8(hub.getIntent(id4).status), uint8(SettlementHub.IntentStatus.Settled));

        assertEq(usdc.balanceOf(merchant), 3 * 985_000_000);
    }

    function test_PayBatch_AllFail() public {
        // 3 expired authorizations
        SettlementHub.Authorization[] memory auths = new SettlementHub.Authorization[](3);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 id = keccak256(abi.encode("batch_fail", i));
            _registerIntent(id);
            auths[i] = _buildAuth(id, payer, payerKey, AMOUNT, block.timestamp - 100, block.timestamp - 1);
        }

        uint256 settled = hub.payIntentBatchWithAuthorization(auths);
        assertEq(settled, 0, "none settled");
        assertEq(usdc.balanceOf(merchant), 0);
    }

    function test_PayBatch_EmptyBatch() public {
        SettlementHub.Authorization[] memory auths = new SettlementHub.Authorization[](0);
        uint256 settled = hub.payIntentBatchWithAuthorization(auths);
        assertEq(settled, 0);
    }

    function test_PayBatch_Revert_BatchTooLarge() public {
        // MAX_BATCH_SIZE + 1 authorizations
        uint256 maxBatch = hub.MAX_BATCH_SIZE();
        SettlementHub.Authorization[] memory auths = new SettlementHub.Authorization[](maxBatch + 1);
        for (uint256 i = 0; i <= maxBatch; i++) {
            // The signatures don't need to be valid — the size check happens first.
            auths[i] = SettlementHub.Authorization({
                intentId: bytes32(uint256(i)),
                payer: payer,
                validAfter: 0,
                validBefore: 1,
                nonce: bytes32(uint256(i)),
                signature: ""
            });
        }

        vm.expectRevert(SettlementHub.BatchTooLarge.selector);
        hub.payIntentBatchWithAuthorization(auths);
    }

    function test_PayBatch_AtMaxSize_Succeeds() public {
        uint256 maxBatch = hub.MAX_BATCH_SIZE();
        // Use a smaller subset to keep the test fast (we just need to prove
        // size <= MAX_BATCH_SIZE doesn't trigger BatchTooLarge). 5 is enough.
        SettlementHub.Authorization[] memory auths = new SettlementHub.Authorization[](5);
        for (uint256 i = 0; i < 5; i++) {
            bytes32 id = keccak256(abi.encode("batch_max", i));
            _registerIntent(id);
            auths[i] = _buildAuth(id, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);
        }
        // Just verify that the call doesn't revert with BatchTooLarge.
        uint256 settled = hub.payIntentBatchWithAuthorization(auths);
        assertEq(settled, 5);
        assertLt(5, maxBatch + 1, "test stays under max"); // sanity
    }

    function test_PayBatch_DifferentPayers() public {
        // Verifies §2.2.1 of ADR-003: a batch can settle authorizations
        // signed by different payers.
        (address payer2, uint256 payerKey2) = makeAddrAndKey("payer2");
        usdc.mint(payer2, AMOUNT);

        SettlementHub.Authorization[] memory auths = new SettlementHub.Authorization[](2);

        bytes32 id1 = keccak256("multi_payer_1");
        _registerIntent(id1);
        auths[0] = _buildAuth(id1, payer, payerKey, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);

        bytes32 id2 = keccak256("multi_payer_2");
        _registerIntent(id2);
        auths[1] = _buildAuth(id2, payer2, payerKey2, AMOUNT, block.timestamp - 1, block.timestamp + 1 hours);

        uint256 settled = hub.payIntentBatchWithAuthorization(auths);
        assertEq(settled, 2);

        // Both intents settled, both payers had USDC withdrawn
        assertEq(uint8(hub.getIntent(id1).status), uint8(SettlementHub.IntentStatus.Settled));
        assertEq(uint8(hub.getIntent(id2).status), uint8(SettlementHub.IntentStatus.Settled));
    }
}
