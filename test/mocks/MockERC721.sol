// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {NFTPawnShop} from "../../src/NFTPawnShop.sol";

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract MockERC721 {
    mapping(uint256 => address) internal _owners;
    mapping(uint256 => address) public getApproved;

    error InvalidTransfer();
    error NotAuthorized();
    error MissingToken();

    function mint(address to, uint256 tokenId) external {
        require(to != address(0) && _owners[tokenId] == address(0));
        _owners[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) public view virtual returns (address) {
        if (_owners[tokenId] == address(0)) revert MissingToken();
        return _owners[tokenId];
    }

    function approve(address to, uint256 tokenId) external {
        if (msg.sender != _owners[tokenId]) revert NotAuthorized();
        getApproved[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual {
        if (from == address(0) || _owners[tokenId] != from || to == address(0)) revert InvalidTransfer();
        if (msg.sender != from && msg.sender != getApproved[tokenId]) revert NotAuthorized();
        _owners[tokenId] = to;
        delete getApproved[tokenId];
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "")
                    == IERC721Receiver.onERC721Received.selector
            );
        }
    }
}

/// @dev Tries every shop entry point; it fails the outer transaction if any bypasses the guard.
library CallbackProbe {
    function payloads() internal pure returns (bytes[9] memory data) {
        data[0] = abi.encodeCall(NFTPawnShop.request, (address(1), 0, 1, 0, 1 hours));
        data[1] = abi.encodeCall(NFTPawnShop.cancel, (0));
        data[2] = abi.encodeCall(NFTPawnShop.fund, (0));
        data[3] = abi.encodeCall(NFTPawnShop.repay, (0));
        data[4] = abi.encodeCall(NFTPawnShop.claim, (0));
        data[5] = abi.encodeCall(NFTPawnShop.withdraw, ());
        data[6] = abi.encodeCall(NFTPawnShop.loanCount, ());
        data[7] = abi.encodeCall(NFTPawnShop.loan, (0));
        data[8] = abi.encodeCall(NFTPawnShop.withdrawable, (address(1)));
    }

    function check(bool ok, bytes memory result) internal pure {
        require(!ok && keccak256(result) == keccak256(abi.encodeWithSelector(NFTPawnShop.Reentrancy.selector)));
    }

    function attack(address shop) internal {
        bytes[9] memory data = payloads();
        for (uint256 i; i < data.length; ++i) {
            (bool ok, bytes memory result) = shop.call(data[i]);
            check(ok, result);
        }
    }

    function attackView(address shop) internal view {
        bytes[9] memory data = payloads();
        for (uint256 i; i < data.length; ++i) {
            (bool ok, bytes memory result) = shop.staticcall(data[i]);
            check(ok, result);
        }
    }
}

contract AdversarialERC721 is MockERC721 {
    address public immutable shop;
    bool public rejectTransfers;
    bool public skipTransfers;
    bool public lie;
    bool public callbacks;
    uint256 public callbackCount;

    error TransferRejected();

    constructor(address shop_) {
        shop = shop_;
    }

    function configure(bool reject_, bool skip_, bool lie_, bool callbacks_) external {
        rejectTransfers = reject_;
        skipTransfers = skip_;
        lie = lie_;
        callbacks = callbacks_;
    }

    function actualOwner(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        if (callbacks) CallbackProbe.attackView(shop);
        if (lie) return shop;
        return super.ownerOf(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (rejectTransfers) revert TransferRejected();
        if (callbacks) {
            ++callbackCount;
            CallbackProbe.attack(shop);
        }
        if (!skipTransfers) super.transferFrom(from, to, tokenId);
    }
}

/// @dev No NFT receiver hook: collateral must be returned by ordinary transferFrom.
contract CreditReceiver {
    address public immutable shop;
    bool public rejectETH;
    bool public callbacks;
    uint256 public received;

    constructor(address shop_) {
        shop = shop_;
    }

    function configure(bool reject_, bool callbacks_) external {
        rejectETH = reject_;
        callbacks = callbacks_;
    }

    receive() external payable {
        require(!rejectETH, "ETH rejected");
        if (callbacks) CallbackProbe.attack(shop);
        received += msg.value;
    }
}
