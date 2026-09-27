// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {NFTPawnShop} from "../src/NFTPawnShop.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract PawnHandler is Test {
    NFTPawnShop public immutable shop;
    MockERC721 public immutable nft;
    address[4] private _actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    mapping(address => uint256) public expectedCredit;
    uint256 public deposited;
    uint256 public paidOut;
    uint256 public nextTokenId;

    constructor(NFTPawnShop shop_, MockERC721 nft_) {
        shop = shop_;
        nft = nft_;
    }

    function actor(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function request(uint256 who, uint256 principal, uint256 interest, uint256 duration) external {
        if (shop.loanCount() >= 32) return;
        address borrower = _actors[who % 4];
        uint256 tokenId = nextTokenId++;
        nft.mint(borrower, tokenId);
        vm.startPrank(borrower);
        nft.approve(address(shop), tokenId);
        shop.request(
            address(nft),
            tokenId,
            bound(principal, 1, 10 ether),
            bound(interest, 0, 5 ether),
            bound(duration, 1 hours, 365 days)
        );
        vm.stopPrank();
    }

    function repawn(uint256 seed) external {
        if (shop.loanCount() == 0 || shop.loanCount() >= 32) return;
        NFTPawnShop.Loan memory item = shop.loan(seed % shop.loanCount());
        address current = nft.ownerOf(item.tokenId);
        if (current == address(shop)) return;
        vm.startPrank(current);
        nft.approve(address(shop), item.tokenId);
        shop.request(address(nft), item.tokenId, item.principal, item.interest, item.duration);
        vm.stopPrank();
    }

    function fund(uint256 seed, uint256 who) external {
        if (shop.loanCount() == 0) return;
        uint256 id = seed % shop.loanCount();
        NFTPawnShop.Loan memory item = shop.loan(id);
        if (item.state != NFTPawnShop.State.Requested) return;
        address lender = _actors[who % 4];
        vm.deal(lender, lender.balance + item.principal);
        vm.prank(lender);
        shop.fund{value: item.principal}(id);
        expectedCredit[item.borrower] += item.principal;
        deposited += item.principal;
    }

    function cancel(uint256 seed) external {
        if (shop.loanCount() == 0) return;
        uint256 id = seed % shop.loanCount();
        NFTPawnShop.Loan memory item = shop.loan(id);
        if (item.state != NFTPawnShop.State.Requested) return;
        vm.prank(item.borrower);
        shop.cancel(id);
    }

    function repay(uint256 seed, uint256 who) external {
        if (shop.loanCount() == 0) return;
        uint256 id = seed % shop.loanCount();
        NFTPawnShop.Loan memory item = shop.loan(id);
        if (item.state != NFTPawnShop.State.Funded || block.timestamp > item.deadline) return;
        _repay(id, item, _actors[who % 4]);
    }

    function claim(uint256 seed) external {
        if (shop.loanCount() == 0) return;
        uint256 id = seed % shop.loanCount();
        NFTPawnShop.Loan memory item = shop.loan(id);
        if (item.state != NFTPawnShop.State.Funded || block.timestamp <= item.deadline) return;
        vm.prank(item.lender);
        shop.claim(id);
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 400 days));
    }

    function withdraw(uint256 who) external {
        _withdraw(_actors[who % 4]);
    }

    function _repay(uint256 id, NFTPawnShop.Loan memory item, address payer) private {
        uint256 debt = item.principal + item.interest;
        vm.deal(payer, payer.balance + debt);
        vm.prank(payer);
        shop.repay{value: debt}(id);
        expectedCredit[item.lender] += debt;
        deposited += debt;
    }

    function _withdraw(address account) private {
        uint256 amount = expectedCredit[account];
        if (amount == 0) return;
        uint256 before = account.balance;
        vm.prank(account);
        shop.withdraw();
        assertEq(account.balance - before, amount, "payout differs from independent credit model");
        expectedCredit[account] = 0;
        paidOut += amount;
    }

    /// @dev Demonstrate that every honest loan and credit can finish after an arbitrary history.
    function closeAll() external {
        for (uint256 id; id < shop.loanCount(); ++id) {
            NFTPawnShop.Loan memory item = shop.loan(id);
            if (item.state == NFTPawnShop.State.Requested) {
                vm.prank(item.borrower);
                shop.cancel(id);
            } else if (item.state == NFTPawnShop.State.Funded) {
                if (block.timestamp > item.deadline) {
                    vm.prank(item.lender);
                    shop.claim(id);
                } else {
                    _repay(id, item, item.borrower);
                }
            }
        }
        for (uint256 i; i < 4; ++i) {
            _withdraw(_actors[i]);
        }
        assertEq(address(shop).balance, 0, "unrecoverable ETH in honest lifecycle");
        assertEq(deposited, paidOut);
    }
}

contract NFTPawnShopInvariantTest is StdInvariant, Test {
    NFTPawnShop private shop;
    MockERC721 private nft;
    PawnHandler private handler;

    function setUp() public {
        shop = new NFTPawnShop();
        nft = new MockERC721();
        handler = new PawnHandler(shop, nft);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PawnHandler.request.selector;
        selectors[1] = PawnHandler.repawn.selector;
        selectors[2] = PawnHandler.fund.selector;
        selectors[3] = PawnHandler.cancel.selector;
        selectors[4] = PawnHandler.repay.selector;
        selectors[5] = PawnHandler.claim.selector;
        selectors[6] = PawnHandler.advanceTime.selector;
        selectors[7] = PawnHandler.withdraw.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ETHBalanceEqualsAllCreditsAndNetDeposits() public view {
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            address account = handler.actor(i);
            uint256 credit = shop.withdrawable(account);
            assertEq(credit, handler.expectedCredit(account));
            total += credit;
        }
        assertEq(address(shop).balance, total);
        assertEq(address(shop).balance, handler.deposited() - handler.paidOut());
    }

    function invariant_everyLiveLoanOwnsItsCollateral() public view {
        for (uint256 i; i < shop.loanCount(); ++i) {
            NFTPawnShop.Loan memory item = shop.loan(i);
            if (item.state == NFTPawnShop.State.Requested || item.state == NFTPawnShop.State.Funded) {
                assertEq(nft.ownerOf(item.tokenId), address(shop));
                for (uint256 j = i + 1; j < shop.loanCount(); ++j) {
                    NFTPawnShop.Loan memory other = shop.loan(j);
                    if (other.state == NFTPawnShop.State.Requested || other.state == NFTPawnShop.State.Funded) {
                        assertTrue(item.nft != other.nft || item.tokenId != other.tokenId, "collateral pledged twice");
                    }
                }
            }
        }
    }

    function afterInvariant() public {
        handler.closeAll();
    }
}
