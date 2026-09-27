# ABI integration reference

The sibling `abi/*.json` files are complete compiler-generated ABI arrays,
including constructors, events, errors, and functions. Both constructors take
no arguments and are nonpayable.

## NFTPawnShop

`loanCount()` returns `uint256`. `loan(uint256)` returns one tuple with these
components, in order:

| Field | ABI type | Meaning |
| --- | --- | --- |
| borrower | address | NFT depositor and recipient on cancel/repay |
| lender | address | Funder; zero before funding |
| nft | address | User-selected collection |
| tokenId | uint256 | Collection token ID |
| principal | uint256 | Wei payable on funding |
| interest | uint256 | Flat interest in wei |
| duration | uint256 | Seconds after funding |
| deadline | uint256 | Unix timestamp; zero before funding |
| state | uint8 | 0 Requested, 1 Cancelled, 2 Funded, 3 Repaid, 4 Defaulted |

`withdrawable(address)` returns that account's total outstanding ETH credit in
wei, summed across loans. These views revert with `Reentrancy()` when called from
a callback during any shop mutation. Normal off-chain reads are unaffected.

| Function signature | Mutability | Return |
| --- | --- | --- |
| `request(address,uint256,uint256,uint256,uint256)` | nonpayable | uint256 loanId |
| `cancel(uint256)` | nonpayable | none |
| `fund(uint256)` | payable | none |
| `repay(uint256)` | payable | none |
| `claim(uint256)` | nonpayable | none |
| `withdraw()` | nonpayable | none |
| `loanCount()` | view | uint256 |
| `loan(uint256)` | view | Loan tuple |
| `withdrawable(address)` | view | uint256 |

Parameter order for request is `(nft, tokenId, principal, interest, duration)`.
Only fund and repay accept ETH; wrong values revert without retaining payment.
No fallback, receive function, or ERC-721 receiver hook is present.

| Event | Indexed fields | Other fields |
| --- | --- | --- |
| Requested | loanId, borrower, nft | tokenId, principal, interest, duration |
| Cancelled | loanId | none |
| Funded | loanId, lender | deadline |
| Repaid | loanId, payer | none |
| Claimed | loanId, lender | none |
| Withdrawn | account | amount |

All event numeric fields are uint256 and account fields are addresses. Events
are emitted before interactions, but reverted operations leave no persisted logs.
Use `loan(id)` for authoritative current state.

Custom errors distinguish invalid terms (`InvalidNFT`, `InvalidPrincipal`,
`InvalidDuration`, `DebtOverflow`), missing/state-invalid loans (`UnknownLoan`,
`WrongState`), unauthorized roles (`NotBorrower`, `NotLender`), amount errors
(`IncorrectValue`), failed custody (`NotInCustody`), deadlines
(`RepaymentExpired`, `NotExpired`), withdrawal errors (`NothingToWithdraw`,
`WithdrawalFailed`), and callbacks (`Reentrancy`). All take no arguments.
Collection errors, malformed return data, and standard arithmetic errors may
also bubble/revert; clients must handle arbitrary revert data.

## LaunchToken

Standard ERC-20 surface: `name`, `symbol`, `decimals`, `totalSupply`,
`balanceOf(address)`, `allowance(address,address)`, `approve(address,uint256)`,
`transfer(address,uint256)`, and `transferFrom(address,address,uint256)`.
Writes return true on success and revert on failure. Values are PAWN minor
units, not ETH wei. Events are standard `Transfer` and `Approval`; finite
allowance consumption does not emit an additional Approval event.

All failures use no-argument errors: `InvalidSender`, `InvalidReceiver`,
`InvalidSpender`, `InsufficientBalance`, or `InsufficientAllowance`.
There is no permit extension, mint function, burn function, or admin ABI.
