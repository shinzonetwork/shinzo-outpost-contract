// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ShinzoChallengeIssuerV1} from "../src/ShinzoChallengeIssuerV1.sol";

// Simulates what the relayer does when it sees a block with a matching extraData tag.
// Resolves the pointer embedded in extraData to an attestation and prints its core data.
//
// Required env:
//   ISSUER      - address of the deployed ShinzoChallengeIssuerV1
//   EXTRA_DATA  - 32-byte block.extraData as hex (e.g. 0x5348<30 hex chars>)
//
// forge script script/RelayerFromExtraData.s.sol --rpc-url $RPC_URL

contract RelayerFromExtraData is Script {
    function run() public view {
        ShinzoChallengeIssuerV1 issuer = ShinzoChallengeIssuerV1(
            vm.envAddress("ISSUER")
        );

        bytes memory extraData = vm.envBytes("EXTRA_DATA");
        require(extraData.length == 32, "EXTRA_DATA must be 32 bytes");

        // Validate tag.
        require(
            extraData[0] == 0x53 && extraData[1] == 0x48,
            "extraData does not start with SH tag"
        );

        uint256 attestationId = issuer.resolveFromExtraData(extraData);
        console.log("Resolved attestation ID:", attestationId);

        (
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
        ) = issuer.attestationCore(attestationId);

        console.log("Withdrawal address:", withdrawalAddress);
        console.log("Delegate key:");
        console.logBytes32(delegateKey);
        console.log("Consensus public key:");
        console.logBytes(consensusPubKey);
        console.log("Created at:        ", createdAt);
        console.log("Signature deadline:", signatureDeadline);
        console.log("Signature submitted:", signatureSubmitted);
        if (signatureSubmitted) {
            console.log("Submitted at:", signatureSubmittedAt);
            console.log("Withdrawal signature:");
            console.logBytes(withdrawalSignature);
            console.log("Pointer:"); console.logBytes15(pointer);
            console.log("Delegate signature:");
            console.logBytes(delegateSignature);

            bytes32 digest = issuer.attestationDigest(attestationId);
            console.log("Digest (to pass as DelegateDigest to MsgIndexerAttestation):");
            console.logBytes32(digest);
        }
    }
}
