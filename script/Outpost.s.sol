// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Outpost} from "../src/Outpost.sol";

contract OutpostScript is Script {
    Outpost public outpost;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // outpost =  Outpost(address(0x5FbDB2315678afecb367f032d93F642f64180aa3));

        outpost = new Outpost();
    
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        outpost.payment{value: 1}(Outpost.Resource.VIEW, "identity2", "streamid", 10);
        vm.stopBroadcast();
    }
}

// forge script script/Outpost.s.sol --rpc-url http://127.0.0.1:8545 --private-key <private-key> --broadcast