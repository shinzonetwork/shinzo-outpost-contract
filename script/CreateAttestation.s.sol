// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ShinzoChallengeIssuerV1} from "../src/ShinzoChallengeIssuerV1.sol";

// Creates an attestation challenge on behalf of the withdrawal address (broadcaster).
//
// Required env:
//   ISSUER          - address of the deployed ShinzoChallengeIssuerV1
//   CONSENSUS_PUBKEY - hex-encoded consensus public key bytes (e.g. 0x04abcd...)
//   DELEGATE_KEY    - address of the delegate (e.g. 0x1234...)
//
// forge script script/CreateAttestation.s.sol \
//   --rpc-url $RPC_URL --private-key $WITHDRAWAL_PK --broadcast

contract CreateAttestation is Script {
    function run() public {
        ShinzoChallengeIssuerV1 issuer = ShinzoChallengeIssuerV1(
            vm.envAddress("ISSUER")
        );

        bytes   memory consensusPubKey = vm.envBytes("CONSENSUS_PUBKEY");
        address        delegateKey     = vm.envAddress("DELEGATE_KEY");

        vm.startBroadcast();

        (uint256 attestationId, bytes32 digest) =
            issuer.createAttestation(consensusPubKey, delegateKey);

        vm.stopBroadcast();

        console.log("Attestation ID:  ", attestationId);
        console.log("Digest (sign this with both keys):");
        console.logBytes32(digest);
        console.log("");
        console.log("Next step: both the withdrawal address and the delegate");
        console.log("must sign the digest above, then call SubmitAttestationSignature.");
    }
}
