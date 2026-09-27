// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Pawn");
        assertEq(token.symbol(), "PAWN");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        vm.expectEmit(true, true, false, true, address(token));
        emit LaunchToken.Transfer(address(this), ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_selfAndZeroTransfers() public {
        token.transfer(address(this), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_approvalAndTransferFrom() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit LaunchToken.Approval(address(this), ALICE, 100);
        assertTrue(token.approve(ALICE, 100));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 40));
        assertEq(token.allowance(address(this), ALICE), 60);
        assertEq(token.balanceOf(BOB), 40);
        token.approve(ALICE, 0);
        vm.prank(ALICE);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_infiniteAllowanceAndSelfTransferFrom() public {
        token.approve(ALICE, type(uint256).max);
        vm.startPrank(ALICE);
        token.transferFrom(address(this), BOB, 50);
        token.transferFrom(address(this), address(this), 100);
        vm.stopPrank();
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        assertEq(token.balanceOf(address(this)), 1e27 - 50);
    }

    function test_invalidTransfersAndApproval() public {
        vm.expectRevert(LaunchToken.InvalidSender.selector);
        token.transferFrom(address(0), BOB, 0);
        vm.expectRevert(LaunchToken.InvalidReceiver.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(LaunchToken.InvalidSpender.selector);
        token.approve(address(0), 1);
        vm.prank(ALICE);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(BOB, 1);
        token.approve(ALICE, 1e27 + 1);
        vm.prank(ALICE);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transferFrom(address(this), BOB, 1e27 + 1);
        assertEq(token.allowance(address(this), ALICE), 1e27 + 1);
        vm.prank(ALICE);
        vm.expectRevert(LaunchToken.InvalidReceiver.selector);
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), ALICE), 1e27 + 1);
    }

    function test_unknownAdminSelectorsRevertForEveryone() public {
        bytes[6] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, 1),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("upgradeTo(address)", ALICE),
            abi.encodeWithSignature("initialize(address)", ALICE),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("burn(uint256)", 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerOK,) = address(token).call(calls[i]);
            vm.prank(ALICE);
            (bool attackerOK,) = address(token).call(calls[i]);
            assertFalse(deployerOK);
            assertFalse(attackerOK);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }
}
