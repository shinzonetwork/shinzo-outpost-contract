// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Outpost} from "../src/Outpost.sol";

contract OutpostTest is Test {
    Outpost public outpost;

    function setUp() public {
        outpost = new Outpost();
        vm.deal(address(this), 100 ether);
    }

    function test_setup() public {
        uint256 initialCount = outpost.paymentCount(address(this));
        assertEq(initialCount, 0);
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 1);
        assertEq(outpost.paymentCount(address(this)), 1);
    }

    function test_PaymentPrimitive() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 1);
        assertEq(outpost.paymentCount(address(this)), 1);
    }

    function test_PaymentView() public {
        outpost.payment{value: 1}(Outpost.Resource.VIEW, "identity1", "streamid", 1);
        assertEq(outpost.paymentCount(address(this)), 1);
    }

    function test_FailPayment() public {
        vm.expectRevert();
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "", "streamid", 1);
    }

    function test_FailPaymentEnum() public {
        vm.expectRevert();
        outpost.payment{value: 1}(Outpost.Resource(1), "", "streamid", 1);
    }

    function testFuzz_Payment(uint256 value) public {
        vm.assume(value > 0);
        vm.assume(value < 100 ether);

        outpost.payment{value: value}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 1);
        assertEq(outpost.paymentCount(address(this)), 1);
    }


    function test_FailExpirePayment() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        vm.warp(block.timestamp + 1);
        vm.expectRevert();
        outpost.expirePayment(address(this), 0);
    }

    function test_ExpirePayment() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        vm.warp(block.timestamp + 11);
        outpost.expirePayment(address(this), 0);
        Outpost.PaymentReceipt memory p = outpost.getPayment(address(this), 0);
        assertEq(p.expired, true);
    }
}
