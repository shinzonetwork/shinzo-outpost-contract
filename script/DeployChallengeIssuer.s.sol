// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ShinzoChallengeIssuerV1} from "../src/ShinzoChallengeIssuerV1.sol";

contract DeployChallengeIssuer is Script {
    function run() public {
        vm.startBroadcast();

        ShinzoChallengeIssuerV1 issuer = new ShinzoChallengeIssuerV1();

        console.log("ShinzoChallengeIssuerV1 deployed at:", address(issuer));
        console.logBytes32(issuer.DOMAIN_SEPARATOR());

        vm.stopBroadcast();
    }
}

// forge script script/DeployChallengeIssuer.s.sol \
//   --rpc-url $RPC_URL --private-key $PK --broadcast
