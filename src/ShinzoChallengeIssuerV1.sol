// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ShinzoChallengeIssuerV1
 * @notice V1 EVM-side "RegistrationIntent -> Challenge" contract.
 *
 * ## What this contract does
 * - A validator (using their WITHDRAWAL key) calls `registrationIntent(...)`.
 * - The contract stores a minimal "intent" record and emits an event containing an EIP-712 `digest`.
 * - The validator signs the EIP-712 typed data offchain (MetaMask `eth_signTypedData_v4`) to produce `withdrawSig`.
 * - The validator computes a 32-byte `commit` and places it in the SOURCE CHAIN block graffiti.
 * - Your relayer watches source-chain blocks for graffiti, verifies proposer + signature offchain,
 *   and then registers the validator on Shinzo.
 *
 * ## Important: There is NO finalize on this EVM contract
 * This EVM contract is only used to issue a canonical EIP-712 challenge/digest and emit it.
 *
 * ---
 *
 * # What exactly goes into graffiti?
 *
 * After `registrationIntent(...)`, the contract emits `RegistrationIntentCreated(...)` with:
 * - `intentId`
 * - `digest` (EIP-712 digest that must be signed)
 *
 * The validator must:
 *
 * 1) Sign the EIP-712 typed data (same fields used to compute `digest`) with their withdrawal key:
 *    withdrawSig = SignTypedDataV4(domain, RegistrationChallenge(message))
 *
 * 2) Compute the graffiti commitment:
 *
 *    commit = keccak256( abi.encodePacked(digest, withdrawSig) )
 *
 * 3) Put the commitment into the SOURCE CHAIN block graffiti, prefixed for scanning:
 *
 *    "SHINZO:" + hex(commit)
 *
 * Only `commit` needs to be in graffiti. Everything else is recoverable from the event + intentId.
 *
 * ---
 *
 * # Relayer offchain verification checklist (not enforced on EVM)
 * For a given intentId:
 * - Obtain `digest` from the event (or recompute via `getDigest(intentId)`).
 * - Validate the block proposer matches the validator's consensus identity (chain-specific).
 * - Validate EIP-712 signature: recover signer == withdrawalAddress
 * - Validate commit: commit == keccak256(digest || withdrawSig)
 * - Validate time: now <= expiresAt
 *
 * Then relay the proof to Shinzo to finalize registration there.
 */
contract ShinzoChallengeIssuerV1 {
    // ----------------------------
    // EIP-712 domain
    // ----------------------------
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant NAME_HASH = keccak256("Shinzo Validator Registration");
    bytes32 private constant VERSION_HASH = keccak256("1");

    /**
     * @notice The typed data schema validators sign.
     *
     * Keep this stable. Changing it changes the meaning of signatures.
     *
     * RegistrationChallenge fields:
     * - intentId: unique id emitted by this contract
     * - withdrawalAddress: must equal msg.sender at intent creation (V1)
     * - delegateKey: Shinzo address equivalent (bytes32)
     * - consensusKeyHash: keccak256(consensusPubKeyBytes) from source chain
     * - issuedAt: timestamp when intent created
     * - expiresAt: timestamp when intent expires
     */
    bytes32 public constant REGISTRATION_TYPEHASH = keccak256(
        "RegistrationChallenge(uint256 intentId,address withdrawalAddress,bytes32 delegateKey,bytes32 consensusKeyHash,uint64 issuedAt,uint64 expiresAt)"
    );

    // ----------------------------
    // State
    // ----------------------------
    uint256 public nextIntentId = 1;

    struct Intent {
        address withdrawalAddress; // msg.sender
        bytes32 delegateKey; // Shinzo address-equivalent (bytes32)
        bytes32 consensusKeyHash; // keccak256(consensusPubKeyBytes)
        uint64 issuedAt;
        uint64 expiresAt;
        bool exists;
    }

    mapping(uint256 => Intent) public intents;

    /**
     * @notice Emitted when a validator creates a registration intent.
     *
     * The `digest` is the EIP-712 digest that MUST be signed by the validator's withdrawal key.
     *
     * ## What validator writes to graffiti (source chain)
     *
     * Let:
     * - withdrawSig = signature produced by signing the EIP-712 typed data whose digest == `digest`
     *
     * Then compute:
     * - commit = keccak256( abi.encodePacked(digest, withdrawSig) )
     *
     * And place in graffiti as:
     * - "SHINZO:" + hex(commit)
     */
    event RegistrationIntentCreated(
        uint256 indexed intentId,
        address indexed withdrawalAddress,
        bytes32 indexed consensusKeyHash,
        bytes32 delegateKey,
        uint64 expiresAt,
        bytes32 digest
    );

    // ----------------------------
    // Main: RegistrationIntent
    // ----------------------------
    /**
     * @notice Create an intent and receive the canonical EIP-712 digest to sign.
     *
     * @param consensusPubKeyBytes The validator's consensus pubkey bytes on the SOURCE chain.
     *                            (ed25519/bls/etc is fine; we store only keccak256 hash)
     * @param delegateKey Shinzo address equivalent (bytes32). This becomes the operator identity on Shinzo.
     * @param validitySeconds How long the intent is valid from now (seconds).
     *
     * @return intentId Unique id for this intent
     * @return digest   EIP-712 digest the withdrawal key must sign (TypedData V4)
     */
    function registrationIntent(bytes calldata consensusPubKeyBytes, bytes32 delegateKey, uint64 validitySeconds)
        external
        returns (uint256 intentId, bytes32 digest)
    {
        require(delegateKey != bytes32(0), "delegate=0");
        require(validitySeconds > 0, "validity=0");

        address withdrawalAddress = msg.sender;
        bytes32 consensusKeyHash = keccak256(consensusPubKeyBytes);

        intentId = nextIntentId++;
        uint64 issuedAt = uint64(block.timestamp);
        uint64 expiresAt = issuedAt + validitySeconds;

        intents[intentId] = Intent({
            withdrawalAddress: withdrawalAddress,
            delegateKey: delegateKey,
            consensusKeyHash: consensusKeyHash,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            exists: true
        });

        // EIP-712 digest user must sign with withdrawal key:
        // digest = keccak256("\x19\x01" || domainSeparator || structHash)
        digest = _hashTypedData(
            keccak256(
                abi.encode(
                    REGISTRATION_TYPEHASH,
                    intentId,
                    withdrawalAddress,
                    delegateKey,
                    consensusKeyHash,
                    issuedAt,
                    expiresAt
                )
            )
        );

        emit RegistrationIntentCreated(intentId, withdrawalAddress, consensusKeyHash, delegateKey, expiresAt, digest);
    }

    /**
     * @notice Recompute the EIP-712 digest for an existing intent.
     * @dev Useful for relayers and clients.
     */
    function getDigest(uint256 intentId) external view returns (bytes32 digest) {
        Intent memory it = intents[intentId];
        require(it.exists, "no intent");

        digest = _hashTypedData(
            keccak256(
                abi.encode(
                    REGISTRATION_TYPEHASH,
                    intentId,
                    it.withdrawalAddress,
                    it.delegateKey,
                    it.consensusKeyHash,
                    it.issuedAt,
                    it.expiresAt
                )
            )
        );
    }

    /**
     * @notice EIP-712 domain separator for clients.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    // ----------------------------
    // EIP-712 internals
    // ----------------------------
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }
}
