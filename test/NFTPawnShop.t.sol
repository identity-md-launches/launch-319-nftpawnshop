// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NFTPawnShop} from "../src/NFTPawnShop.sol";
import {MockERC721, AdversarialERC721, CreditReceiver} from "./mocks/MockERC721.sol";

contract NFTPawnShopTest is Test {
    NFTPawnShop private shop;
    MockERC721 private nft;
    address private constant BORROWER = address(0xB0B);
    address private constant LENDER = address(0xA11CE);
    address private constant OTHER = address(0xCAFE);
    uint256 private constant PRINCIPAL = 1 ether;
    uint256 private constant INTEREST = 0.1 ether;

    function setUp() public {
        shop = new NFTPawnShop();
        nft = new MockERC721();
        vm.deal(BORROWER, 100 ether);
        vm.deal(LENDER, 100 ether);
        vm.deal(OTHER, 100 ether);
        vm.warp(1_000_000);
    }

    function _request(MockERC721 collection, address borrower, uint256 tokenId) private returns (uint256) {
        collection.mint(borrower, tokenId);
        vm.startPrank(borrower);
        collection.approve(address(shop), tokenId);
        uint256 id = shop.request(address(collection), tokenId, PRINCIPAL, INTEREST, 1 days);
        vm.stopPrank();
        return id;
    }

    function _fund(uint256 id, address lender) private {
        vm.prank(lender);
        shop.fund{value: PRINCIPAL}(id);
    }

    function _assertState(uint256 id, NFTPawnShop.State expected) private view {
        assertEq(uint256(shop.loan(id).state), uint256(expected));
    }

    function test_requestRecordsTermsCustodyAndEvent() public {
        nft.mint(BORROWER, 42);
        vm.startPrank(BORROWER);
        nft.approve(address(shop), 42);
        vm.expectEmit(true, true, true, true, address(shop));
        emit NFTPawnShop.Requested(0, BORROWER, address(nft), 42, PRINCIPAL, INTEREST, 1 days);
        assertEq(shop.request(address(nft), 42, PRINCIPAL, INTEREST, 1 days), 0);
        vm.stopPrank();
        NFTPawnShop.Loan memory item = shop.loan(0);
        assertEq(item.borrower, BORROWER);
        assertEq(item.lender, address(0));
        assertEq(item.nft, address(nft));
        assertEq(item.tokenId, 42);
        assertEq(item.principal, PRINCIPAL);
        assertEq(item.interest, INTEREST);
        assertEq(item.duration, 1 days);
        assertEq(item.deadline, 0);
        _assertState(0, NFTPawnShop.State.Requested);
        assertEq(shop.loanCount(), 1);
        assertEq(nft.ownerOf(42), address(shop));
        assertEq(address(shop).balance, 0);
    }

    function test_requestValidationAndMissingApproval() public {
        nft.mint(BORROWER, 1);
        vm.startPrank(BORROWER);
        vm.expectRevert(NFTPawnShop.InvalidNFT.selector);
        shop.request(address(0), 1, PRINCIPAL, 0, 1 hours);
        vm.expectRevert(NFTPawnShop.InvalidNFT.selector);
        shop.request(OTHER, 1, PRINCIPAL, 0, 1 hours);
        vm.expectRevert(NFTPawnShop.InvalidPrincipal.selector);
        shop.request(address(nft), 1, 0, 0, 1 hours);
        vm.expectRevert(NFTPawnShop.InvalidDuration.selector);
        shop.request(address(nft), 1, PRINCIPAL, 0, 1 hours - 1);
        vm.expectRevert(NFTPawnShop.InvalidDuration.selector);
        shop.request(address(nft), 1, PRINCIPAL, 0, 365 days + 1);
        vm.expectRevert(NFTPawnShop.DebtOverflow.selector);
        shop.request(address(nft), 1, 1, type(uint256).max, 1 hours);
        vm.expectRevert(MockERC721.NotAuthorized.selector);
        shop.request(address(nft), 1, PRINCIPAL, 0, 1 hours);
        vm.stopPrank();
        vm.prank(OTHER);
        vm.expectRevert(MockERC721.InvalidTransfer.selector);
        shop.request(address(nft), 1, PRINCIPAL, 0, 1 hours);
        assertEq(shop.loanCount(), 0);
        assertEq(nft.ownerOf(1), BORROWER);
    }

    function test_durationBoundsZeroInterestAndOneWeiPrincipal() public {
        for (uint256 i; i < 2; ++i) {
            nft.mint(BORROWER, i);
            vm.startPrank(BORROWER);
            nft.approve(address(shop), i);
            shop.request(address(nft), i, 1, 0, i == 0 ? 1 hours : 365 days);
            vm.stopPrank();
            vm.prank(LENDER);
            shop.fund{value: 1}(i);
            vm.prank(OTHER);
            shop.repay{value: 1}(i);
            assertEq(nft.ownerOf(i), BORROWER);
        }
        assertEq(shop.withdrawable(BORROWER), 2);
        assertEq(shop.withdrawable(LENDER), 2);
        assertEq(address(shop).balance, 4);
    }

    function test_cancelOnlyBorrowerAndRepawnAfterCancellation() public {
        uint256 id = _request(nft, BORROWER, 1);
        vm.prank(OTHER);
        vm.expectRevert(NFTPawnShop.NotBorrower.selector);
        shop.cancel(id);
        vm.expectEmit(true, false, false, true, address(shop));
        emit NFTPawnShop.Cancelled(id);
        vm.prank(BORROWER);
        shop.cancel(id);
        _assertState(id, NFTPawnShop.State.Cancelled);
        assertEq(nft.ownerOf(1), BORROWER);
        vm.startPrank(BORROWER);
        nft.approve(address(shop), 1);
        assertEq(shop.request(address(nft), 1, PRINCIPAL, 0, 1 hours), 1);
        vm.stopPrank();
        assertEq(shop.loanCount(), 2);
        _assertState(0, NFTPawnShop.State.Cancelled);
        _assertState(1, NFTPawnShop.State.Requested);
    }

    function test_fundExactlyOnceAndWithdrawBorrowerCredit() public {
        uint256 id = _request(nft, BORROWER, 1);
        vm.prank(LENDER);
        vm.expectRevert(NFTPawnShop.IncorrectValue.selector);
        shop.fund{value: PRINCIPAL - 1}(id);
        vm.prank(LENDER);
        vm.expectRevert(NFTPawnShop.IncorrectValue.selector);
        shop.fund{value: PRINCIPAL + 1}(id);
        uint256 before = BORROWER.balance;
        vm.expectEmit(true, true, false, true, address(shop));
        emit NFTPawnShop.Funded(id, LENDER, block.timestamp + 1 days);
        _fund(id, LENDER);
        _assertState(id, NFTPawnShop.State.Funded);
        assertEq(shop.loan(id).lender, LENDER);
        assertEq(shop.loan(id).deadline, block.timestamp + 1 days);
        assertEq(BORROWER.balance, before);
        assertEq(shop.withdrawable(BORROWER), PRINCIPAL);
        vm.expectEmit(true, false, false, true, address(shop));
        emit NFTPawnShop.Withdrawn(BORROWER, PRINCIPAL);
        vm.prank(BORROWER);
        shop.withdraw();
        assertEq(BORROWER.balance, before + PRINCIPAL);
        assertEq(shop.withdrawable(BORROWER), 0);
        assertEq(address(shop).balance, 0);
        vm.prank(BORROWER);
        vm.expectRevert(NFTPawnShop.NothingToWithdraw.selector);
        shop.withdraw();
    }

    function test_anyoneRepaysAtDeadlineAndClaimIsTooEarly() public {
        uint256 id = _request(nft, BORROWER, 1);
        _fund(id, LENDER);
        vm.warp(shop.loan(id).deadline);
        vm.prank(LENDER);
        vm.expectRevert(NFTPawnShop.NotExpired.selector);
        shop.claim(id);
        vm.prank(OTHER);
        vm.expectRevert(NFTPawnShop.IncorrectValue.selector);
        shop.repay{value: PRINCIPAL + INTEREST - 1}(id);
        vm.prank(OTHER);
        vm.expectRevert(NFTPawnShop.IncorrectValue.selector);
        shop.repay{value: PRINCIPAL + INTEREST + 1}(id);
        vm.expectEmit(true, true, false, true, address(shop));
        emit NFTPawnShop.Repaid(id, OTHER);
        vm.prank(OTHER);
        shop.repay{value: PRINCIPAL + INTEREST}(id);
        _assertState(id, NFTPawnShop.State.Repaid);
        assertEq(nft.ownerOf(1), BORROWER);
        assertEq(shop.withdrawable(LENDER), PRINCIPAL + INTEREST);
        assertEq(address(shop).balance, 2 * PRINCIPAL + INTEREST);
        vm.warp(block.timestamp + 1);
        vm.prank(LENDER);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.claim(id);
        vm.prank(BORROWER);
        shop.withdraw();
        vm.prank(LENDER);
        shop.withdraw();
        assertEq(address(shop).balance, 0);
        assertEq(shop.withdrawable(LENDER), 0);
        vm.startPrank(BORROWER);
        nft.approve(address(shop), 1);
        assertEq(shop.request(address(nft), 1, PRINCIPAL, 0, 1 hours), 1);
        vm.stopPrank();
    }

    function test_onlyLenderClaimsAtDeadlinePlusOneAndRepayIsTooLate() public {
        uint256 id = _request(nft, BORROWER, 1);
        _fund(id, LENDER);
        vm.prank(LENDER);
        vm.expectRevert(NFTPawnShop.NotExpired.selector);
        shop.claim(id);
        vm.warp(shop.loan(id).deadline + 1);
        vm.prank(OTHER);
        vm.expectRevert(NFTPawnShop.RepaymentExpired.selector);
        shop.repay{value: PRINCIPAL + INTEREST}(id);
        vm.prank(BORROWER);
        vm.expectRevert(NFTPawnShop.NotLender.selector);
        shop.claim(id);
        vm.prank(OTHER);
        vm.expectRevert(NFTPawnShop.NotLender.selector);
        shop.claim(id);
        vm.expectEmit(true, true, false, true, address(shop));
        emit NFTPawnShop.Claimed(id, LENDER);
        vm.prank(LENDER);
        shop.claim(id);
        _assertState(id, NFTPawnShop.State.Defaulted);
        assertEq(nft.ownerOf(1), LENDER);
        assertEq(shop.withdrawable(LENDER), 0);
        assertEq(shop.withdrawable(BORROWER), PRINCIPAL);
        vm.prank(BORROWER);
        shop.withdraw();
        assertEq(address(shop).balance, 0);
        vm.startPrank(LENDER);
        nft.approve(address(shop), 1);
        shop.request(address(nft), 1, PRINCIPAL, 0, 1 hours);
        vm.stopPrank();
        assertEq(shop.loan(1).borrower, LENDER);
    }

    function test_borrowerMaySelfFundAndCreditsAggregate() public {
        uint256 id = _request(nft, BORROWER, 1);
        _fund(id, BORROWER);
        vm.prank(BORROWER);
        shop.repay{value: PRINCIPAL + INTEREST}(id);
        assertEq(shop.withdrawable(BORROWER), 2 * PRINCIPAL + INTEREST);
        vm.prank(BORROWER);
        shop.withdraw();
        assertEq(address(shop).balance, 0);
        assertEq(BORROWER.balance, 100 ether);
    }

    function test_unfundedRequestsDoNotExpireAndDeadlineStartsAtFunding() public {
        uint256 id = _request(nft, BORROWER, 1);
        uint256 fundingTime = vm.getBlockTimestamp() + 730 days;
        vm.warp(fundingTime);
        _fund(id, LENDER);
        assertEq(shop.loan(id).deadline, fundingTime + 1 days);
        vm.prank(BORROWER);
        shop.repay{value: PRINCIPAL + INTEREST}(id);
        assertEq(nft.ownerOf(1), BORROWER);
    }

    function test_forcedSurplusDoesNotIncreaseAnyoneCredit() public {
        uint256 id = _request(nft, BORROWER, 1);
        _fund(id, LENDER);
        // Model an EVM-level forced transfer without adding a selfdestruct artifact.
        vm.deal(address(shop), address(shop).balance + 7);
        assertEq(shop.withdrawable(BORROWER), PRINCIPAL);
        assertEq(shop.withdrawable(LENDER), 0);
        assertEq(shop.withdrawable(OTHER), 0);
        vm.prank(BORROWER);
        shop.withdraw();
        assertEq(address(shop).balance, 7);
        vm.prank(OTHER);
        vm.expectRevert(NFTPawnShop.NothingToWithdraw.selector);
        shop.withdraw();
    }

    function test_allActionsRejectUnknownLoan() public {
        vm.expectRevert(NFTPawnShop.UnknownLoan.selector);
        shop.loan(0);
        vm.expectRevert(NFTPawnShop.UnknownLoan.selector);
        shop.cancel(0);
        vm.expectRevert(NFTPawnShop.UnknownLoan.selector);
        shop.fund(0);
        vm.expectRevert(NFTPawnShop.UnknownLoan.selector);
        shop.repay(0);
        vm.expectRevert(NFTPawnShop.UnknownLoan.selector);
        shop.claim(type(uint256).max);
    }

    function _rejectTerminalActions(uint256 id, address borrower) private {
        vm.startPrank(borrower);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.cancel(id);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.fund{value: PRINCIPAL}(id);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.repay{value: PRINCIPAL + INTEREST}(id);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.claim(id);
        vm.stopPrank();
    }

    function test_invalidAndDuplicateTransitionsInEveryState() public {
        uint256 cancelled = _request(nft, BORROWER, 1);
        vm.prank(BORROWER);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.repay{value: PRINCIPAL + INTEREST}(cancelled);
        vm.prank(LENDER);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.claim(cancelled);
        vm.prank(BORROWER);
        shop.cancel(cancelled);
        _rejectTerminalActions(cancelled, BORROWER);

        uint256 repaid = _request(nft, BORROWER, 2);
        _fund(repaid, LENDER);
        vm.prank(OTHER);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.fund{value: PRINCIPAL}(repaid);
        vm.prank(BORROWER);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.cancel(repaid);
        vm.prank(BORROWER);
        shop.repay{value: PRINCIPAL + INTEREST}(repaid);
        _rejectTerminalActions(repaid, BORROWER);

        uint256 defaulted = _request(nft, BORROWER, 3);
        _fund(defaulted, LENDER);
        vm.warp(shop.loan(defaulted).deadline + 1);
        vm.prank(LENDER);
        shop.claim(defaulted);
        _rejectTerminalActions(defaulted, BORROWER);
        vm.prank(LENDER);
        vm.expectRevert(NFTPawnShop.WrongState.selector);
        shop.claim(defaulted);
    }

    function test_cannotPawnAlreadyEscrowedNFT() public {
        _request(nft, BORROWER, 1);
        vm.prank(BORROWER);
        vm.expectRevert(MockERC721.InvalidTransfer.selector);
        shop.request(address(nft), 1, PRINCIPAL, 0, 1 hours);
        assertEq(shop.loanCount(), 1);
        assertEq(nft.ownerOf(1), address(shop));
    }

    function test_straySafeTransferRevertsButPlainTransferIsUntracked() public {
        nft.mint(BORROWER, 1);
        vm.prank(BORROWER);
        vm.expectRevert();
        nft.safeTransferFrom(BORROWER, address(shop), 1);
        assertEq(nft.ownerOf(1), BORROWER);
        vm.prank(BORROWER);
        nft.transferFrom(BORROWER, address(shop), 1);
        assertEq(nft.ownerOf(1), address(shop));
        assertEq(shop.loanCount(), 0);
    }

    function test_noReceiveFallbackOrPayableRequest() public {
        vm.deal(address(this), 1 ether);
        (bool direct,) = address(shop).call{value: 1}("");
        (bool unknown,) = address(shop).call(hex"deadbeef");
        (bool requestPaid,) = address(shop).call{value: 1}(
            abi.encodeCall(NFTPawnShop.request, (address(nft), 1, PRINCIPAL, INTEREST, 1 days))
        );
        assertFalse(direct);
        assertFalse(unknown);
        assertFalse(requestPaid);
        assertEq(address(shop).balance, 0);
    }

    function test_everyEntryPointBlocksNFTCallbacksOnEveryTransferPath() public {
        AdversarialERC721 evil = new AdversarialERC721(address(shop));
        evil.configure(false, false, false, true);
        uint256 cancelId = _request(evil, BORROWER, 1);
        vm.prank(BORROWER);
        shop.cancel(cancelId);
        uint256 repayId = _request(evil, BORROWER, 2);
        _fund(repayId, LENDER);
        vm.prank(OTHER);
        shop.repay{value: PRINCIPAL + INTEREST}(repayId);
        uint256 claimId = _request(evil, BORROWER, 3);
        _fund(claimId, LENDER);
        vm.warp(shop.loan(claimId).deadline + 1);
        vm.prank(LENDER);
        shop.claim(claimId);
        assertEq(evil.callbackCount(), 6);
        assertEq(shop.loanCount(), 3);
        assertEq(shop.withdrawable(BORROWER), 2 * PRINCIPAL);
        assertEq(shop.withdrawable(LENDER), PRINCIPAL + INTEREST);
        assertEq(address(shop).balance, 3 * PRINCIPAL + INTEREST);
        evil.configure(false, false, false, false);
        assertEq(evil.ownerOf(1), BORROWER);
        assertEq(evil.ownerOf(2), BORROWER);
        assertEq(evil.ownerOf(3), LENDER);
    }

    function test_transferAndPostOwnershipFailuresRollBackRequest() public {
        AdversarialERC721 evil = new AdversarialERC721(address(shop));
        evil.mint(BORROWER, 1);
        vm.prank(BORROWER);
        evil.approve(address(shop), 1);
        evil.configure(true, false, false, false);
        vm.prank(BORROWER);
        vm.expectRevert(AdversarialERC721.TransferRejected.selector);
        shop.request(address(evil), 1, PRINCIPAL, INTEREST, 1 days);
        evil.configure(false, true, false, false);
        vm.prank(BORROWER);
        vm.expectRevert(NFTPawnShop.NotInCustody.selector);
        shop.request(address(evil), 1, PRINCIPAL, INTEREST, 1 days);
        assertEq(shop.loanCount(), 0);
        assertEq(evil.actualOwner(1), BORROWER);
    }

    function test_failedCancelRepayAndClaimPreserveStateAndMoney() public {
        AdversarialERC721 evil = new AdversarialERC721(address(shop));
        uint256 id = _request(evil, BORROWER, 1);
        evil.configure(true, false, false, false);
        vm.prank(BORROWER);
        vm.expectRevert(AdversarialERC721.TransferRejected.selector);
        shop.cancel(id);
        _assertState(id, NFTPawnShop.State.Requested);
        _fund(id, LENDER);
        uint256 before = OTHER.balance;
        vm.prank(OTHER);
        vm.expectRevert(AdversarialERC721.TransferRejected.selector);
        shop.repay{value: PRINCIPAL + INTEREST}(id);
        assertEq(OTHER.balance, before);
        assertEq(shop.withdrawable(LENDER), 0);
        assertEq(address(shop).balance, PRINCIPAL);
        _assertState(id, NFTPawnShop.State.Funded);
        vm.warp(shop.loan(id).deadline + 1);
        vm.prank(LENDER);
        vm.expectRevert(AdversarialERC721.TransferRejected.selector);
        shop.claim(id);
        _assertState(id, NFTPawnShop.State.Funded);
        assertEq(evil.actualOwner(1), address(shop));
        vm.prank(BORROWER);
        shop.withdraw();
        assertEq(address(shop).balance, 0);
        evil.configure(false, false, false, false);
        vm.prank(LENDER);
        shop.claim(id);
        assertEq(evil.actualOwner(1), LENDER);
    }

    function test_fakeCollectionCanLieButCannotCreateOrDoublePayETH() public {
        AdversarialERC721 fake = new AdversarialERC721(address(shop));
        fake.configure(false, true, true, true);
        uint256 id = _request(fake, BORROWER, 1);
        assertEq(fake.actualOwner(1), BORROWER);
        _fund(id, LENDER);
        vm.prank(BORROWER);
        shop.withdraw();
        assertEq(address(shop).balance, 0);
        vm.warp(shop.loan(id).deadline + 1);
        vm.prank(LENDER);
        shop.claim(id);
        _assertState(id, NFTPawnShop.State.Defaulted);
        assertEq(fake.actualOwner(1), BORROWER);
        assertEq(shop.withdrawable(LENDER), 0);
        vm.prank(BORROWER);
        vm.expectRevert(NFTPawnShop.NothingToWithdraw.selector);
        shop.withdraw();

        uint256 second = _request(fake, BORROWER, 2);
        _fund(second, LENDER);
        vm.prank(OTHER);
        shop.repay{value: PRINCIPAL + INTEREST}(second);
        assertEq(address(shop).balance, 2 * PRINCIPAL + INTEREST);
        assertEq(shop.withdrawable(BORROWER) + shop.withdrawable(LENDER), address(shop).balance);
        vm.prank(LENDER);
        shop.withdraw();
        vm.prank(BORROWER);
        shop.withdraw();
        assertEq(address(shop).balance, 0);
    }

    function test_failedReceiverCannotBlockOtherCreditsAndMayRetry() public {
        CreditReceiver receiver = new CreditReceiver(address(shop));
        receiver.configure(true, false);
        uint256 id = _request(nft, address(receiver), 1);
        _fund(id, LENDER);
        vm.prank(address(receiver));
        vm.expectRevert(NFTPawnShop.WithdrawalFailed.selector);
        shop.withdraw();
        assertEq(shop.withdrawable(address(receiver)), PRINCIPAL);
        vm.prank(OTHER);
        shop.repay{value: PRINCIPAL + INTEREST}(id);
        assertEq(nft.ownerOf(1), address(receiver));
        vm.prank(LENDER);
        shop.withdraw();
        assertEq(address(shop).balance, PRINCIPAL);
        receiver.configure(false, true);
        vm.prank(address(receiver));
        shop.withdraw();
        assertEq(receiver.received(), PRINCIPAL);
        assertEq(shop.withdrawable(address(receiver)), 0);
        assertEq(address(shop).balance, 0);
    }

    function test_contractLenderNeedsNoNFTReceiverHookToClaim() public {
        CreditReceiver receiver = new CreditReceiver(address(shop));
        uint256 id = _request(nft, BORROWER, 1);
        vm.deal(address(receiver), PRINCIPAL);
        _fund(id, address(receiver));
        vm.warp(shop.loan(id).deadline + 1);
        vm.prank(address(receiver));
        shop.claim(id);
        assertEq(nft.ownerOf(1), address(receiver));
    }

    function test_multipleLoansAccumulateCreditsIndependently() public {
        for (uint256 i; i < 3; ++i) {
            _request(nft, BORROWER, i);
            _fund(i, LENDER);
            vm.prank(OTHER);
            shop.repay{value: PRINCIPAL + INTEREST}(i);
        }
        assertEq(shop.withdrawable(BORROWER), 3 * PRINCIPAL);
        assertEq(shop.withdrawable(LENDER), 3 * (PRINCIPAL + INTEREST));
        assertEq(address(shop).balance, 6 * PRINCIPAL + 3 * INTEREST);
        vm.prank(LENDER);
        shop.withdraw();
        vm.prank(BORROWER);
        shop.withdraw();
        assertEq(address(shop).balance, 0);
    }
}
