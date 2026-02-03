// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ShinzoChallengeIssuerV1} from "../src/ShinzoChallengeIssuerV1.sol";

contract ShinzoChallengeIssuerV1Test is Test {
    ShinzoChallengeIssuerV1 public issuer;

    // EIP-712 constants (must match contract)
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("Shinzo Validator Registration");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 private constant REGISTRATION_TYPEHASH = keccak256(
        "RegistrationChallenge(uint256 intentId,address withdrawalAddress,bytes32 delegateKey,bytes32 consensusKeyHash,uint64 issuedAt,uint64 expiresAt)"
    );

    // Test accounts
    address validator1;
    uint256 validator1Pk;
    address validator2;
    uint256 validator2Pk;

    // Test data
    bytes constant CONSENSUS_PUBKEY = hex"abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";
    bytes32 constant DELEGATE_KEY = bytes32(uint256(0x123456789));
    uint64 constant VALIDITY_SECONDS = 3600; // 1 hour

    function setUp() public {
        issuer = new ShinzoChallengeIssuerV1();
        (validator1, validator1Pk) = makeAddrAndKey("validator1");
        (validator2, validator2Pk) = makeAddrAndKey("validator2");
    }

    // ============================================
    // 1. registrationIntent() Tests
    // ============================================

    // 1.1 Successfully creates intent and returns valid intentId (starts at 1, increments)
    function test_registrationIntent_ReturnsValidIntentId() public {
        vm.prank(validator1);
        (uint256 intentId1,) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);
        assertEq(intentId1, 1, "First intentId should be 1");

        vm.prank(validator2);
        (uint256 intentId2,) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);
        assertEq(intentId2, 2, "Second intentId should be 2");

        assertEq(issuer.nextIntentId(), 3, "nextIntentId should be 3 after two intents");
    }

    // 1.2 Returns correct EIP-712 digest
    function test_registrationIntent_ReturnsCorrectDigest() public {
        vm.warp(1000); // Set timestamp for predictability

        vm.prank(validator1);
        (uint256 intentId, bytes32 digest) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);

        // Manually compute expected digest
        bytes32 expectedDigest = _computeExpectedDigest(
            intentId, validator1, DELEGATE_KEY, keccak256(CONSENSUS_PUBKEY), 1000, 1000 + VALIDITY_SECONDS
        );

        assertEq(digest, expectedDigest, "Digest should match expected EIP-712 digest");
    }

    // 1.3 Stores correct Intent struct
    function test_registrationIntent_StoresCorrectIntentStruct() public {
        vm.warp(1000);

        vm.prank(validator1);
        (uint256 intentId,) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);

        (
            address withdrawalAddress,
            bytes32 delegateKey,
            bytes32 consensusKeyHash,
            uint64 issuedAt,
            uint64 expiresAt,
            bool exists
        ) = issuer.intents(intentId);

        assertEq(withdrawalAddress, validator1, "withdrawalAddress should be validator1");
        assertEq(delegateKey, DELEGATE_KEY, "delegateKey should match");
        assertEq(consensusKeyHash, keccak256(CONSENSUS_PUBKEY), "consensusKeyHash should be keccak256 of pubkey");
        assertEq(issuedAt, 1000, "issuedAt should be block.timestamp");
        assertEq(expiresAt, 1000 + VALIDITY_SECONDS, "expiresAt should be issuedAt + validitySeconds");
        assertTrue(exists, "exists should be true");
    }

    // 1.4 Emits RegistrationIntentCreated event with correct parameters
    function test_registrationIntent_EmitsEvent() public {
        vm.warp(1000);

        bytes32 expectedConsensusKeyHash = keccak256(CONSENSUS_PUBKEY);
        uint64 expectedExpiresAt = 1000 + VALIDITY_SECONDS;

        // Compute expected digest
        bytes32 expectedDigest = _computeExpectedDigest(
            1, // intentId will be 1
            validator1,
            DELEGATE_KEY,
            expectedConsensusKeyHash,
            1000,
            expectedExpiresAt
        );

        vm.expectEmit(true, true, true, true);
        emit ShinzoChallengeIssuerV1.RegistrationIntentCreated(
            1, validator1, expectedConsensusKeyHash, DELEGATE_KEY, expectedExpiresAt, expectedDigest
        );

        vm.prank(validator1);
        issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);
    }

    // 1.5 Reverts when delegateKey == bytes32(0)
    function test_registrationIntent_RevertsOnZeroDelegateKey() public {
        vm.prank(validator1);
        vm.expectRevert("delegate=0");
        issuer.registrationIntent(CONSENSUS_PUBKEY, bytes32(0), VALIDITY_SECONDS);
    }

    // 1.6 Reverts when validitySeconds == 0
    function test_registrationIntent_RevertsOnZeroValidity() public {
        vm.prank(validator1);
        vm.expectRevert("validity=0");
        issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, 0);
    }

    // 1.7 consensusKeyHash is correctly computed as keccak256(consensusPubKeyBytes)
    function test_registrationIntent_ConsensusKeyHashComputation() public {
        bytes memory customPubKey = hex"deadbeef";
        bytes32 expectedHash = keccak256(customPubKey);

        vm.prank(validator1);
        (uint256 intentId,) = issuer.registrationIntent(customPubKey, DELEGATE_KEY, VALIDITY_SECONDS);

        (,, bytes32 consensusKeyHash,,,) = issuer.intents(intentId);
        assertEq(consensusKeyHash, expectedHash, "consensusKeyHash should be keccak256 of input bytes");
    }

    // 1.8 expiresAt equals issuedAt + validitySeconds
    function test_registrationIntent_ExpiresAtCalculation() public {
        vm.warp(5000);
        uint64 customValidity = 7200;

        vm.prank(validator1);
        (uint256 intentId,) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, customValidity);

        (,,, uint64 issuedAt, uint64 expiresAt,) = issuer.intents(intentId);
        assertEq(issuedAt, 5000, "issuedAt should be block.timestamp");
        assertEq(expiresAt, 5000 + customValidity, "expiresAt should be issuedAt + validitySeconds");
    }

    // ============================================
    // 2. getDigest() Tests
    // ============================================

    // 2.1 Returns same digest as emitted during registrationIntent()
    function test_getDigest_MatchesEmittedDigest() public {
        vm.prank(validator1);
        (uint256 intentId, bytes32 emittedDigest) =
            issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);

        bytes32 retrievedDigest = issuer.getDigest(intentId);
        assertEq(retrievedDigest, emittedDigest, "getDigest should return same digest as emitted");
    }

    // 2.2 Reverts for non-existent intentId
    function test_getDigest_RevertsForNonExistentIntent() public {
        vm.expectRevert("no intent");
        issuer.getDigest(999);
    }

    // ============================================
    // 3. domainSeparator() Tests
    // ============================================

    // 3.1 Returns correct EIP-712 domain separator
    function test_domainSeparator_ReturnsCorrectValue() public view {
        bytes32 expectedDomainSeparator =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(issuer)));

        assertEq(issuer.domainSeparator(), expectedDomainSeparator, "domainSeparator should match expected");
    }

    // 3.2 Domain separator includes correct chainId and verifyingContract
    function test_domainSeparator_IncludesChainIdAndContract() public {
        // Deploy on different chain
        vm.chainId(137); // Polygon
        ShinzoChallengeIssuerV1 polygonIssuer = new ShinzoChallengeIssuerV1();

        bytes32 expectedPolygonDomain =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, 137, address(polygonIssuer)));

        assertEq(polygonIssuer.domainSeparator(), expectedPolygonDomain, "Domain separator should use correct chainId");

        // Verify different contracts have different domain separators
        ShinzoChallengeIssuerV1 anotherIssuer = new ShinzoChallengeIssuerV1();
        assertTrue(
            polygonIssuer.domainSeparator() != anotherIssuer.domainSeparator(),
            "Different contracts should have different domain separators"
        );
    }

    // ============================================
    // 4. EIP-712 Signature Verification (offchain simulation)
    // ============================================

    // 4.1 Recovered signer from signed digest matches withdrawalAddress
    function test_signatureVerification_RecoveredSignerMatchesWithdrawalAddress() public {
        vm.prank(validator1);
        (uint256 intentId, bytes32 digest) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);

        // Sign the digest with validator1's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Pk, digest);

        // Recover signer
        address recoveredSigner = ecrecover(digest, v, r, s);
        assertEq(recoveredSigner, validator1, "Recovered signer should match withdrawalAddress");

        // Verify intent's withdrawalAddress
        (address withdrawalAddress,,,,,) = issuer.intents(intentId);
        assertEq(recoveredSigner, withdrawalAddress, "Recovered signer should match stored withdrawalAddress");
    }

    // 4.2 Graffiti commit computation produces expected 32-byte value
    function test_graffitiCommit_ComputationIsCorrect() public {
        vm.prank(validator1);
        (, bytes32 digest) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator1Pk, digest);
        bytes memory withdrawSig = abi.encodePacked(r, s, v);

        // Compute commit as specified in contract comments:
        // commit = keccak256( abi.encodePacked(digest, withdrawSig) )
        bytes32 commit = keccak256(abi.encodePacked(digest, withdrawSig));

        // Verify commit is 32 bytes (always true for keccak256)
        assertTrue(commit != bytes32(0), "Commit should be non-zero");

        // Verify commit is deterministic
        bytes32 commit2 = keccak256(abi.encodePacked(digest, withdrawSig));
        assertEq(commit, commit2, "Commit should be deterministic");

        // Verify different signatures produce different commits
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(validator2Pk, digest);
        bytes memory differentSig = abi.encodePacked(r2, s2, v2);
        bytes32 differentCommit = keccak256(abi.encodePacked(digest, differentSig));
        assertTrue(commit != differentCommit, "Different signatures should produce different commits");
    }

    // ============================================
    // 5. State Management Tests
    // ============================================

    // 5.1 nextIntentId increments correctly after each intent
    function test_nextIntentId_IncrementsCorrectly() public {
        assertEq(issuer.nextIntentId(), 1, "Initial nextIntentId should be 1");

        vm.prank(validator1);
        issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);
        assertEq(issuer.nextIntentId(), 2, "nextIntentId should be 2 after first intent");

        vm.prank(validator1);
        issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);
        assertEq(issuer.nextIntentId(), 3, "nextIntentId should be 3 after second intent");

        vm.prank(validator2);
        issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);
        assertEq(issuer.nextIntentId(), 4, "nextIntentId should be 4 after third intent");
    }

    // 5.2 Multiple intents can be created by same address
    function test_multipleIntents_SameAddress() public {
        bytes32 delegateKey1 = bytes32(uint256(1));
        bytes32 delegateKey2 = bytes32(uint256(2));
        bytes32 delegateKey3 = bytes32(uint256(3));

        vm.startPrank(validator1);
        (uint256 id1,) = issuer.registrationIntent(CONSENSUS_PUBKEY, delegateKey1, VALIDITY_SECONDS);
        (uint256 id2,) = issuer.registrationIntent(CONSENSUS_PUBKEY, delegateKey2, VALIDITY_SECONDS);
        (uint256 id3,) = issuer.registrationIntent(CONSENSUS_PUBKEY, delegateKey3, VALIDITY_SECONDS);
        vm.stopPrank();

        // Verify all intents exist and have correct data
        (, bytes32 dk1,,,,) = issuer.intents(id1);
        (, bytes32 dk2,,,,) = issuer.intents(id2);
        (, bytes32 dk3,,,,) = issuer.intents(id3);

        assertEq(dk1, delegateKey1, "Intent 1 delegateKey should match");
        assertEq(dk2, delegateKey2, "Intent 2 delegateKey should match");
        assertEq(dk3, delegateKey3, "Intent 3 delegateKey should match");
    }

    // 5.3 Multiple intents can be created by different addresses
    function test_multipleIntents_DifferentAddresses() public {
        vm.prank(validator1);
        (uint256 id1,) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);

        vm.prank(validator2);
        (uint256 id2,) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, VALIDITY_SECONDS);

        (address addr1,,,,,) = issuer.intents(id1);
        (address addr2,,,,,) = issuer.intents(id2);

        assertEq(addr1, validator1, "Intent 1 should belong to validator1");
        assertEq(addr2, validator2, "Intent 2 should belong to validator2");
    }

    // 5.4 intents mapping stores and retrieves correctly
    function test_intentsMapping_StoresAndRetrievesCorrectly() public {
        vm.warp(2000);
        bytes memory customPubKey = hex"1234";
        bytes32 customDelegateKey = bytes32(uint256(0xABCDEF));
        uint64 customValidity = 1800;

        vm.prank(validator1);
        (uint256 intentId,) = issuer.registrationIntent(customPubKey, customDelegateKey, customValidity);

        (
            address withdrawalAddress,
            bytes32 delegateKey,
            bytes32 consensusKeyHash,
            uint64 issuedAt,
            uint64 expiresAt,
            bool exists
        ) = issuer.intents(intentId);

        assertEq(withdrawalAddress, validator1);
        assertEq(delegateKey, customDelegateKey);
        assertEq(consensusKeyHash, keccak256(customPubKey));
        assertEq(issuedAt, 2000);
        assertEq(expiresAt, 2000 + customValidity);
        assertTrue(exists);

        // Verify non-existent intent returns default values
        (address noAddr, bytes32 noDk, bytes32 noCkh, uint64 noIssuedAt, uint64 noExpiresAt, bool noExists) =
            issuer.intents(999);

        assertEq(noAddr, address(0));
        assertEq(noDk, bytes32(0));
        assertEq(noCkh, bytes32(0));
        assertEq(noIssuedAt, 0);
        assertEq(noExpiresAt, 0);
        assertFalse(noExists);
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    function testFuzz_registrationIntent_ValiditySeconds(uint64 validitySeconds) public {
        vm.assume(validitySeconds > 0);
        vm.assume(validitySeconds < type(uint64).max - uint64(block.timestamp)); // Prevent overflow

        vm.prank(validator1);
        (uint256 intentId,) = issuer.registrationIntent(CONSENSUS_PUBKEY, DELEGATE_KEY, validitySeconds);

        (,,, uint64 issuedAt, uint64 expiresAt,) = issuer.intents(intentId);
        assertEq(expiresAt, issuedAt + validitySeconds);
    }

    function testFuzz_registrationIntent_DelegateKey(bytes32 delegateKey) public {
        vm.assume(delegateKey != bytes32(0));

        vm.prank(validator1);
        (uint256 intentId,) = issuer.registrationIntent(CONSENSUS_PUBKEY, delegateKey, VALIDITY_SECONDS);

        (, bytes32 storedDelegateKey,,,,) = issuer.intents(intentId);
        assertEq(storedDelegateKey, delegateKey);
    }

    function testFuzz_registrationIntent_ConsensusPubKey(bytes calldata consensusPubKey) public {
        vm.prank(validator1);
        (uint256 intentId,) = issuer.registrationIntent(consensusPubKey, DELEGATE_KEY, VALIDITY_SECONDS);

        (,, bytes32 consensusKeyHash,,,) = issuer.intents(intentId);
        assertEq(consensusKeyHash, keccak256(consensusPubKey));
    }

    // ============================================
    // Helper Functions
    // ============================================

    function _computeExpectedDigest(
        uint256 intentId,
        address withdrawalAddress,
        bytes32 delegateKey,
        bytes32 consensusKeyHash,
        uint64 issuedAt,
        uint64 expiresAt
    ) internal view returns (bytes32) {
        bytes32 domainSep = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(issuer))
        );

        bytes32 structHash = keccak256(
            abi.encode(
                REGISTRATION_TYPEHASH, intentId, withdrawalAddress, delegateKey, consensusKeyHash, issuedAt, expiresAt
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }
}
