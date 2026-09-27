// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPawnERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Permissionless ETH loans against borrower-selected ERC-721 collateral.
/// @dev Lenders must trust each collection's ownership and transfer behavior.
contract NFTPawnShop {
    enum State {
        Requested,
        Cancelled,
        Funded,
        Repaid,
        Defaulted
    }

    struct Loan {
        address borrower;
        address lender;
        address nft;
        uint256 tokenId;
        uint256 principal;
        uint256 interest;
        uint256 duration;
        uint256 deadline;
        State state;
    }

    Loan[] private _loans;
    mapping(address => uint256) private _withdrawable;
    bool private _entered;

    error Reentrancy();
    error InvalidNFT();
    error InvalidPrincipal();
    error InvalidDuration();
    error DebtOverflow();
    error UnknownLoan();
    error WrongState();
    error NotBorrower();
    error NotLender();
    error IncorrectValue();
    error NotInCustody();
    error RepaymentExpired();
    error NotExpired();
    error NothingToWithdraw();
    error WithdrawalFailed();

    event Requested(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed nft,
        uint256 tokenId,
        uint256 principal,
        uint256 interest,
        uint256 duration
    );
    event Cancelled(uint256 indexed loanId);
    event Funded(uint256 indexed loanId, address indexed lender, uint256 deadline);
    event Repaid(uint256 indexed loanId, address indexed payer);
    event Claimed(uint256 indexed loanId, address indexed lender);
    event Withdrawn(address indexed account, uint256 amount);

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /// @dev Views cannot acquire a storage lock, but reject observation during external callbacks.
    modifier nonReentrantView() {
        if (_entered) revert Reentrancy();
        _;
    }

    constructor() {}

    /// @return loanId Zero-based identifier; never reused, including after collateral is returned.
    function request(address nft, uint256 tokenId, uint256 principal, uint256 interest, uint256 duration)
        external
        nonReentrant
        returns (uint256 loanId)
    {
        if (nft.code.length == 0) revert InvalidNFT();
        if (principal == 0) revert InvalidPrincipal();
        if (duration < 1 hours || duration > 365 days) revert InvalidDuration();
        if (interest > type(uint256).max - principal) revert DebtOverflow();

        loanId = _loans.length;
        _loans.push(Loan(msg.sender, address(0), nft, tokenId, principal, interest, duration, 0, State.Requested));
        emit Requested(loanId, msg.sender, nft, tokenId, principal, interest, duration);

        IPawnERC721(nft).transferFrom(msg.sender, address(this), tokenId);
        if (IPawnERC721(nft).ownerOf(tokenId) != address(this)) revert NotInCustody();
    }

    function cancel(uint256 loanId) external nonReentrant {
        Loan storage item = _getLoan(loanId);
        if (item.state != State.Requested) revert WrongState();
        if (msg.sender != item.borrower) revert NotBorrower();
        item.state = State.Cancelled;
        emit Cancelled(loanId);
        IPawnERC721(item.nft).transferFrom(address(this), item.borrower, item.tokenId);
    }

    /// @notice Funding creates a borrower credit; it never calls the borrower.
    function fund(uint256 loanId) external payable nonReentrant {
        Loan storage item = _getLoan(loanId);
        if (item.state != State.Requested) revert WrongState();
        if (msg.value != item.principal) revert IncorrectValue();
        item.lender = msg.sender;
        item.deadline = block.timestamp + item.duration;
        item.state = State.Funded;
        _withdrawable[item.borrower] += msg.value;
        emit Funded(loanId, msg.sender, item.deadline);
    }

    /// @notice Anyone may pay through the deadline, but collateral always returns to the borrower.
    function repay(uint256 loanId) external payable nonReentrant {
        Loan storage item = _getLoan(loanId);
        if (item.state != State.Funded) revert WrongState();
        if (block.timestamp > item.deadline) revert RepaymentExpired();
        if (msg.value != item.principal + item.interest) revert IncorrectValue();
        item.state = State.Repaid;
        _withdrawable[item.lender] += msg.value;
        emit Repaid(loanId, msg.sender);
        IPawnERC721(item.nft).transferFrom(address(this), item.borrower, item.tokenId);
    }

    function claim(uint256 loanId) external nonReentrant {
        Loan storage item = _getLoan(loanId);
        if (item.state != State.Funded) revert WrongState();
        if (msg.sender != item.lender) revert NotLender();
        if (block.timestamp <= item.deadline) revert NotExpired();
        item.state = State.Defaulted;
        emit Claimed(loanId, msg.sender);
        IPawnERC721(item.nft).transferFrom(address(this), item.lender, item.tokenId);
    }

    /// @notice Pull the caller's entire credit. A failed payment leaves that credit intact.
    function withdraw() external nonReentrant {
        uint256 amount = _withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _withdrawable[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert WithdrawalFailed();
    }

    function loanCount() external view nonReentrantView returns (uint256) {
        return _loans.length;
    }

    function loan(uint256 loanId) external view nonReentrantView returns (Loan memory) {
        return _getLoan(loanId);
    }

    function withdrawable(address account) external view nonReentrantView returns (uint256) {
        return _withdrawable[account];
    }

    function _getLoan(uint256 loanId) private view returns (Loan storage) {
        if (loanId >= _loans.length) revert UnknownLoan();
        return _loans[loanId];
    }
}
