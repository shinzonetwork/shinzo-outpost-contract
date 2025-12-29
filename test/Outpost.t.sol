// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Outpost} from "../src/Outpost.sol";

contract OutpostTest is Test {
    Outpost public outpost;

    address admin = address(0x12345);
    address shinzohub = address(0x67890);

    function setUp() public {
        outpost = new Outpost(admin, shinzohub);
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
        vm.prank(shinzohub);
        outpost.expirePayment(address(this), 0);
        vm.stopPrank();
    }

    function test_ExpirePayment() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        vm.warp(block.timestamp + 11);
        vm.prank(shinzohub);
        outpost.expirePayment(address(this), 0);
        vm.stopPrank();
        Outpost.PaymentReceipt memory p = outpost.getPayment(address(this), 0);
        assertEq(p.expired, true);
    }

    function test_GetPayment() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        Outpost.PaymentReceipt memory p = outpost.getPayment(address(this), 0);
        assertEq(uint256(p.resource), uint256(Outpost.Resource.PRIMITIVE));
        assertEq(p.amount, 1);
        assertEq(p.expiration, block.timestamp + 10);
        assertEq(p.timestamp, block.timestamp);
        assertEq(p.expired, false);
    }

    function test_GetPaymentDetails() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        Outpost.PaymentReceipt memory p = outpost.getPayment(address(this), 0);
        assertEq(uint256(p.resource), uint256(Outpost.Resource.PRIMITIVE));
        assertEq(p.amount, 1);
        assertEq(p.expiration, block.timestamp + 10);
        assertEq(p.timestamp, block.timestamp);
        assertEq(p.expired, false);
    }

    function test_GetPaymentDetails2() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        Outpost.PaymentReceipt memory p = outpost.getPayment(address(this), 0);
        assertEq(uint256(p.resource), uint256(Outpost.Resource.PRIMITIVE));
        assertEq(p.amount, 1);
        assertEq(p.expiration, block.timestamp + 10);
        assertEq(p.timestamp, block.timestamp);
        assertEq(p.expired, false);
    }

    function test_Withdraw() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        vm.prank(admin);
        outpost.withdraw();
        assertEq(address(outpost).balance, 0);
    }

    function test_Withdraw_Fail() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        vm.expectRevert();
        outpost.withdraw();
    }

    function test_Withdraw_Success() public {
        outpost.payment{value: 1}(Outpost.Resource.PRIMITIVE, "identity1", "streamid", 10);
        vm.prank(admin);
        outpost.withdraw();
        assertEq(address(outpost).balance, 0);
    }

    function test_Withdraw_EmptyBalance() public {
        // Don't make any payment, contract has 0 balance
        vm.prank(admin);
        outpost.withdraw(); // Should succeed even with 0 balance
        assertEq(address(outpost).balance, 0);
    }
}
