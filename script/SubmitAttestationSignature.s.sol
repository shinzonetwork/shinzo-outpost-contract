// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ShinzoChallengeIssuerV1} from "../src/ShinzoChallengeIssuerV1.sol";

// Submits both the withdrawal address signature and the delegate signature
// for an existing attestation.
//
// The broadcaster must be the withdrawal address that created the attestation.
//
// Required env:
//   ISSUER            - address of the deployed ShinzoChallengeIssuerV1
//   ATTESTATION_ID    - uint256 returned by CreateAttestation
//   WITHDRAWAL_PK     - private key of the withdrawal address (signs the digest)
//   DELEGATE_PK       - private key of the Shinzo/Cosmos delegate (signs the same digest)
//
// forge script script/SubmitAttestationSignature.s.sol \
//   --rpc-url $RPC_URL --private-key $WITHDRAWAL_PK --broadcast

contract SubmitAttestationSignature is Script {
    function run() public {
        ShinzoChallengeIssuerV1 issuer = ShinzoChallengeIssuerV1(
            vm.envAddress("ISSUER")
        );
        uint256 attestationId  = vm.envUint("ATTESTATION_ID");
        uint256 withdrawalPK   = vm.envUint("WITHDRAWAL_PK");
        uint256 delegatePK     = vm.envUint("DELEGATE_PK");

        // Fetch the digest to sign.
        bytes32 digest = issuer.attestationDigest(attestationId);
        console.log("Digest:");
        console.logBytes32(digest);

        // Sign with withdrawal key (EIP-712, no Ethereum prefix — contract accepts both).
        (uint8 wV, bytes32 wR, bytes32 wS) = vm.sign(withdrawalPK, digest);
        bytes memory withdrawalSig = abi.encodePacked(wR, wS, wV);

        // Sign with delegate key (Cosmos/Shinzo secp256k1 key, same raw digest).
        (uint8 dV, bytes32 dR, bytes32 dS) = vm.sign(delegatePK, digest);
        bytes memory delegateSig = abi.encodePacked(dR, dS, dV);

        vm.startBroadcast(withdrawalPK);

        bytes15 pointer = issuer.submitAttestationSignature(
            attestationId,
            withdrawalSig,
            delegateSig
        );

        vm.stopBroadcast();

        // Encode pointer as block.extraData string ("SH" + 30 hex chars).
        string memory extraDataStr = issuer.encodeExtraDataString(pointer);

        console.log("Pointer (bytes15):");
        console.logBytes15(pointer);
        console.log("ExtraData string (set as validator block.extraData):");
        console.log(extraDataStr);
        console.log("");
        console.log("Geth extraData hex (pad extraDataStr to 32 bytes as ASCII):");
        _logGethExtraData(extraDataStr);
    }

    // Prints the 32-byte big-endian hex that Geth expects in --miner.extradata.
    // Format: 2 bytes "SH" tag + 30 ASCII hex chars, right-padded to 32 bytes with zeros.
    function _logGethExtraData(string memory s) internal pure {
        bytes memory b = bytes(s);
        bytes memory padded = new bytes(32);
        for (uint256 i = 0; i < b.length && i < 32; i++) {
            padded[i] = b[i];
        }
        console.log("0x");
        console.logBytes(padded);
    }
}
