// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {ShinzoChallengeIssuerV1} from "../src/ShinzoChallengeIssuerV1.sol";

contract ValidatorChallengeScript is Script {
    ShinzoChallengeIssuerV1 public issuer;

    function run() public {
        vm.startBroadcast();

        issuer = new ShinzoChallengeIssuerV1();

        vm.stopBroadcast();
    }
}

// forge script script/ValidatorChallenge.s.sol --rpc-url <rpc-url> --private-key <private-key> --broadcast
