// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ShinzoChallengeIssuerV1 {
    uint64 public constant SIGNATURE_WINDOW_SECONDS = 3600;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH    = keccak256("Shinzo Validator Registration");
    bytes32 private constant VERSION_HASH = keccak256("1");

    bytes32 public constant ATTESTATION_TYPEHASH =
        keccak256(
            "AttestationChallenge(uint256 attestationId,address withdrawalAddress,bytes32 delegateKey,bytes32 consensusKeyHash,uint64 createdAt,uint64 signatureDeadline)"
        );

    bytes32 public immutable DOMAIN_SEPARATOR;

    bytes2 public constant EXTRADATA_TAG = "SH";

    uint256 private constant POINTER_BYTES     = 15;
    uint256 private constant POINTER_HEX_CHARS = 30;

    bytes16 private constant HEX_CHARS = "0123456789abcdef";

    uint256 private constant SECP256K1N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 private constant SECP256K1N_HALF = SECP256K1N / 2;

    uint256 public nextAttestationId = 1;

    struct Attestation {
        address withdrawalAddress;
        bytes32 delegateKey;
        bytes   consensusPubKey;
        uint64  createdAt;
        uint64  signatureDeadline;
        bool    signatureSubmitted;
        uint64  signatureSubmittedAt;
        bytes   withdrawalSignature;
        bytes   delegateSignature;
        bytes15 pointer;
    }

    mapping(uint256 => Attestation) public attestations;
    mapping(bytes15 => uint256) public pointerToAttestationId;
    mapping(address => uint256) public openAttestationIdByWithdrawal;

    /**
     * Emitted when a new attestation is created via createAttestation.
     *
     * @param attestationId       Auto-incremented attestation identifier.
     * @param withdrawalAddress   The msg.sender who created the attestation (validator).
     * @param consensusKeyHash    keccak256 of the raw consensus public key bytes.
     * @param delegateKey         The delegate key (address zero-padded to bytes32).
     * @param signatureDeadline   Unix timestamp after which signatures are no longer accepted.
     * @param digest              EIP-712 typed-data digest that must be signed by both parties.
     */
    event AttestationCreated(
        uint256 indexed attestationId,
        address indexed withdrawalAddress,
        bytes32 indexed consensusKeyHash,
        bytes32 delegateKey,
        uint64  signatureDeadline,
        bytes32 digest
    );

    /**
     * Emitted when both signatures are submitted via submitAttestationSignature.
     *
     * @param attestationId        The attestation that was signed.
     * @param withdrawalAddress    The validator who owns this attestation.
     * @param pointer              15-byte extraData pointer derived from domain separator + digest + withdrawal sig.
     * @param digest               The EIP-712 digest that was signed.
     * @param signatureSubmittedAt Unix timestamp when the signatures were submitted.
     */
    event AttestationSigned(
        uint256 indexed attestationId,
        address indexed withdrawalAddress,
        bytes15 indexed pointer,
        bytes32 digest,
        uint64  signatureSubmittedAt
    );

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this))
        );
    }

    /**
     * Creates a new attestation challenge for the calling validator.
     * Only one open (unsigned, non-expired) attestation may exist per withdrawal address
     * at a time. If a previous one expired without being signed, it is automatically cleared.
     *
     * @param  consensusPubKeyBytes  Compressed (33 bytes) or uncompressed (65 bytes) secp256k1
     *                               consensus public key of the validator.
     * @param  delegateKey           Delegate address zero-padded to bytes32. This is the key
     *                               that will co-sign the attestation digest.
     * @return attestationId         Auto-incremented identifier for this attestation.
     * @return digest                EIP-712 typed-data digest that both the withdrawal address
     *                               and the delegate must sign before the signature deadline.
     */
    function createAttestation(bytes calldata consensusPubKeyBytes, bytes32 delegateKey)
        external
        returns (uint256 attestationId, bytes32 digest)
    {
        require(
            consensusPubKeyBytes.length == 33 || consensusPubKeyBytes.length == 65,
            "bad pubkey len"
        );
        require(delegateKey != bytes32(0), "delegate=0");

        address withdrawalAddress = msg.sender;

        uint256 openId = openAttestationIdByWithdrawal[withdrawalAddress];
        if (openId != 0) {
            Attestation storage openA = attestations[openId];
            bool stillActive = (!openA.signatureSubmitted) && (block.timestamp <= openA.signatureDeadline);
            require(!stillActive, "active attestation exists");
            openAttestationIdByWithdrawal[withdrawalAddress] = 0;
        }

        bytes32 consensusKeyHash = keccak256(consensusPubKeyBytes);

        attestationId = nextAttestationId++;
        uint64 createdAt       = uint64(block.timestamp);
        uint64 signatureDeadline = createdAt + SIGNATURE_WINDOW_SECONDS;

        attestations[attestationId] = Attestation({
            withdrawalAddress:  withdrawalAddress,
            delegateKey:        delegateKey,
            consensusPubKey:    consensusPubKeyBytes,
            createdAt:          createdAt,
            signatureDeadline:  signatureDeadline,
            signatureSubmitted: false,
            signatureSubmittedAt: 0,
            withdrawalSignature: "",
            delegateSignature:  "",
            pointer:            bytes15(0)
        });

        openAttestationIdByWithdrawal[withdrawalAddress] = attestationId;

        digest = _attestationDigest(
            attestationId, withdrawalAddress, delegateKey,
            consensusKeyHash, createdAt, signatureDeadline
        );

        emit AttestationCreated(
            attestationId, withdrawalAddress, consensusKeyHash,
            delegateKey, signatureDeadline, digest
        );
    }

    /**
     * Submits both signatures for an open attestation. Must be called by the same
     * withdrawal address (msg.sender) that created it, before the signature deadline.
     * The withdrawal signature is verified on-chain against the EIP-712 digest (accepts
     * both raw EIP-712 and eth_sign prefixed signatures). A unique 15-byte pointer is
     * derived and stored, which the validator embeds in block extraData.
     *
     * @param  attestationId        The ID returned by createAttestation.
     * @param  withdrawalSignature  65-byte ECDSA signature of the digest, signed by the
     *                              withdrawal address (validator).
     * @param  delegateSignature    65-byte ECDSA signature of the digest, signed by the
     *                              delegate key.
     * @return pointer              15-byte extraData pointer. Encode with encodeExtraDataString()
     *                              to get the 32-byte hex string for block extraData.
     */
    function submitAttestationSignature(
        uint256 attestationId,
        bytes calldata withdrawalSignature,
        bytes calldata delegateSignature
    )
        external
        returns (bytes15 pointer)
    {
        Attestation storage a = attestations[attestationId];
        require(a.withdrawalAddress != address(0), "no attestation");
        require(!a.signatureSubmitted,              "already signed");
        require(block.timestamp <= a.signatureDeadline, "sig window closed");
        require(msg.sender == a.withdrawalAddress,  "not withdrawal");
        require(withdrawalSignature.length == 65,   "withdrawal sig!=65");
        require(delegateSignature.length == 65,     "delegate sig!=65");

        bytes32 digest = _attestationDigest(
            attestationId, a.withdrawalAddress, a.delegateKey,
            keccak256(a.consensusPubKey), a.createdAt, a.signatureDeadline
        );

        if (!_isValidSignature(a.withdrawalAddress, digest, withdrawalSignature)) {
            bytes32 ethSignedDigest = _toEthSignedMessageHash(digest);
            require(_isValidSignature(a.withdrawalAddress, ethSignedDigest, withdrawalSignature), "bad sig");
        }

        pointer = bytes15(keccak256(abi.encodePacked(DOMAIN_SEPARATOR, digest, withdrawalSignature)));
        require(pointerToAttestationId[pointer] == 0, "pointer used");

        a.signatureSubmitted    = true;
        a.signatureSubmittedAt  = uint64(block.timestamp);
        a.withdrawalSignature   = withdrawalSignature;
        a.delegateSignature     = delegateSignature;
        a.pointer               = pointer;

        pointerToAttestationId[pointer] = attestationId;
        openAttestationIdByWithdrawal[a.withdrawalAddress] = 0;

        emit AttestationSigned(attestationId, a.withdrawalAddress, pointer, digest, a.signatureSubmittedAt);
    }

    function clearExpiredOpenAttestation() external {
        uint256 id = openAttestationIdByWithdrawal[msg.sender];
        require(id != 0, "no open");

        Attestation storage a = attestations[id];
        require(!a.signatureSubmitted,          "already signed");
        require(block.timestamp > a.signatureDeadline, "not expired");

        openAttestationIdByWithdrawal[msg.sender] = 0;
    }

    function resolve(bytes15 pointer) external view returns (uint256 attestationId) {
        attestationId = pointerToAttestationId[pointer];
        require(attestationId != 0, "unknown pointer");
    }

    function attestationDigest(uint256 attestationId) external view returns (bytes32 digest) {
        Attestation storage a = attestations[attestationId];
        require(a.withdrawalAddress != address(0), "no attestation");

        digest = _attestationDigest(
            attestationId, a.withdrawalAddress, a.delegateKey,
            keccak256(a.consensusPubKey), a.createdAt, a.signatureDeadline
        );
    }

    function attestationCore(uint256 attestationId)
        external
        view
        returns (
            address withdrawalAddress,
            bytes32 delegateKey,
            bytes memory consensusPubKey,
            uint64  createdAt,
            uint64  signatureDeadline,
            bool    signatureSubmitted,
            uint64  signatureSubmittedAt,
            bytes memory withdrawalSignature,
            bytes15 pointer,
            bytes memory delegateSignature
        )
    {
        Attestation storage a = attestations[attestationId];
        require(a.withdrawalAddress != address(0), "no attestation");

        withdrawalAddress    = a.withdrawalAddress;
        delegateKey          = a.delegateKey;
        consensusPubKey      = a.consensusPubKey;
        createdAt            = a.createdAt;
        signatureDeadline    = a.signatureDeadline;
        signatureSubmitted   = a.signatureSubmitted;
        signatureSubmittedAt = a.signatureSubmittedAt;
        withdrawalSignature  = a.withdrawalSignature;
        pointer              = a.pointer;
        delegateSignature    = a.delegateSignature;
    }

    function encodeExtraDataString(bytes15 pointer) external pure returns (string memory) {
        return string(abi.encodePacked("SH", _toHex30(pointer)));
    }

    function pointerFromExtraData(bytes calldata headerExtra) external pure returns (bytes15 pointer) {
        return _pointerFromExtraData(headerExtra);
    }

    function resolveFromExtraData(bytes calldata headerExtra) external view returns (uint256 attestationId) {
        bytes15 pointer = _pointerFromExtraData(headerExtra);
        attestationId = pointerToAttestationId[pointer];
        require(attestationId != 0, "unknown pointer");
    }

    function _pointerFromExtraData(bytes calldata headerExtra) internal pure returns (bytes15 pointer) {
        require(headerExtra.length == 32, "extra len != 32");
        require(headerExtra[0] == 0x53 && headerExtra[1] == 0x48, "bad tag");

        uint120 acc = 0;
        for (uint256 i = 0; i < 15; i++) {
            uint8 hi = _fromHexChar(uint8(headerExtra[2 + 2 * i]));
            uint8 lo = _fromHexChar(uint8(headerExtra[2 + 2 * i + 1]));
            acc = (acc << 8) | uint120((hi << 4) | lo);
        }
        pointer = bytes15(acc);
    }

    function _attestationDigest(
        uint256 attestationId,
        address withdrawalAddress,
        bytes32 delegateKey,
        bytes32 consensusKeyHash,
        uint64  createdAt,
        uint64  signatureDeadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                attestationId,
                withdrawalAddress,
                delegateKey,
                consensusKeyHash,
                createdAt,
                signatureDeadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _toEthSignedMessageHash(bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }

    function _isValidSignature(address expectedSigner, bytes32 digest, bytes calldata sig)
        internal
        pure
        returns (bool)
    {
        (bytes32 r, bytes32 s, uint8 v) = _splitSig(sig);

        if (v < 27) v += 27;
        if (v != 27 && v != 28) return false;
        if (uint256(s) > SECP256K1N_HALF) return false;

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) return false;

        return signer == expectedSigner;
    }

    function _splitSig(bytes calldata sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
    }

    function _toHex30(bytes15 data) internal pure returns (bytes memory out) {
        out = new bytes(POINTER_HEX_CHARS);
        for (uint256 i = 0; i < POINTER_BYTES; i++) {
            uint8 b = uint8(data[i]);
            out[2 * i]     = HEX_CHARS[b >> 4];
            out[2 * i + 1] = HEX_CHARS[b & 0x0f];
        }
    }

    function _fromHexChar(uint8 c) internal pure returns (uint8) {
        if (c >= 48 && c <= 57)  return c - 48;
        if (c >= 97 && c <= 102) return c - 87;
        if (c >= 65 && c <= 70)  return c - 55;
        revert("bad hex char");
    }
}
