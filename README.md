# Pawn / PAWN

Foundry implementation for the `lab-nft-pawnshop` project on **Sepolia (11155111)**.
This contribution supplies source, tests, ABI exports, and the contract handoff.
The separate manifest assignment produces `launch.json`; an independent contributor
reviews the accepted contracts and manifest before services admit and deploy them.
Deployment and the website against the live addresses are later stages.

## Contracts

| Contract | Constructor | Purpose |
| --- | --- | --- |
| `src/LaunchToken.sol:LaunchToken` | `[]`, nonpayable | Pawn (`PAWN`), 18 decimals, fixed `10^27` minor units (1 billion PAWN) minted once to the deploying factory |
| `src/NFTPawnShop.sol:NFTPawnShop` | `[]`, nonpayable | Permissionless peer-to-peer ETH loans against ERC-721 collateral |

PAWN is the launch token only. The shop has no token dependency or initial token
allocation. Neither contract has an owner, administrator, upgrade path, mint
entry point, fees, pause, blocklist, or privileged withdrawal. The token implements
ERC-20 transfers, approvals, and allowances; maximum uint256 allowance is infinite.
Finite allowances decrease on `transferFrom`. Supply never changes. Transfers to
zero and approvals of a zero spender revert.

## Loan lifecycle

All monetary amounts are **wei of ETH**, including `interest`, which is a flat
amount rather than a rate. Durations and deadlines are seconds. Loan IDs are
zero-based, monotonically assigned, and never reused. `loan(id)` reverts for a
nonexistent ID. The ABI enum order is Requested=0, Cancelled=1, Funded=2,
Repaid=3, Defaulted=4.

| Call | Conditions | Result |
| --- | --- | --- |
| `request(nft, tokenId, principal, interest, duration)` | Caller owns and approves the NFT; collection has code; principal > 0; principal + interest fits uint256; duration is 3,600–31,536,000 inclusive | Records Requested; pulls NFT using `transferFrom`; checks `ownerOf(tokenId) == shop`; returns loan ID |
| `cancel(id)` | Borrower; Requested | Cancelled; returns NFT to borrower |
| `fund(id)` | Anyone, including borrower; Requested; exact principal as `msg.value` | Funded; caller is lender; deadline is funding block timestamp + duration; credits borrower |
| `repay(id)` | Anyone; Funded; timestamp <= deadline; exact principal + interest | Repaid; credits lender; returns NFT to borrower, regardless of payer |
| `claim(id)` | Lender; Funded; timestamp > deadline | Defaulted; transfers NFT to lender; no ETH credit |
| `withdraw()` | Caller has credit | Clears and sends the caller's entire credit; failed ETH delivery reverts and restores credit |

Requested loans do not expire. Terms cannot be edited. Cancel and create a new
request to change them. A returned NFT may be pawned again under a new ID. At the
deadline second repayment is valid and claiming is invalid; at deadline + 1 the
reverse holds. The timestamp of the included transaction controls the result.
A competing fund/cancel or repay/claim transaction may revert after the first
transaction settles the loan.

Funding and repayment credit pull payments: they never push ETH to borrowers or
lenders. A reverting receiver cannot block other accounts. All accounting/state
effects and events precede outgoing calls; a failing transfer rolls back the
entire operation, including credits, incoming ETH, NFT changes, and logs. Every
mutating external shop function acquires a shared reentrancy lock. The three
views check that same lock and reject callback reads while an operation is in
progress. The lock is released after the external interaction completes.

## Collection and custody assumptions

**The shop cannot vouch for a collection. A fake ERC-721 that lies about
`ownerOf`, or a collection whose transfers revert, can cost its lender the
principal. Lenders choose which collections to trust.** The frontend must show
this warning next to **every loan's collection address**, including on open
requests and active loans. There is no collection allowlist or oracle.

The ownership check catches an ordinary failed deposit; a malicious collection
can fake it. The shop cannot stop an NFT administrator from changing or freezing
collection behavior after funding. The tests demonstrate both a lying collection
and failed outbound transfers while checking that the shop neither invents
credits nor pays twice. A permanently reverting collection can leave its loan
Funded and its collateral unavailable. Previously credited ETH remains withdrawable;
there is no admin recovery or lender refund of the principal already credited to
the borrower. Repayment does not succeed or retain the payer's ETH if the NFT
transfer reverts.

NFT exits use ordinary `transferFrom`, so recipient ERC-721 hooks are not called.
Borrower and lender contract wallets must be able to manage NFTs received this
way and accept ETH from `withdraw()`. There is no alternate withdrawal recipient;
a wallet that permanently rejects ETH leaves its own credit inaccessible.

The shop has no `onERC721Received`, `receive`, or `fallback`. A conforming stray
`safeTransferFrom` reverts. A plain NFT `transferFrom` outside `request()` is
**untracked and unrecoverable**; do not send it. Unsolicited ERC-20 transfers are
also unrecoverable. Ordinary ETH entry is restricted to `fund` and `repay`, but
the EVM can force ETH to an address without invoking its code. Forced ETH is
uncredited surplus and cannot be swept.

The tested balance equality, `shop ETH == sum(withdrawable)`, assumes no forced
ETH. With forced ETH the correct relation is `balance == credits + surplus`.
The custody invariant (every Requested/Funded NFT is owned by the shop) assumes
honest ERC-721 behavior. Neither invariant can make an arbitrary collection
truthful. Stateful tests use an honest collection; separate malicious mocks
exercise the trust boundary and payment conservation.

## Build and verification

Install Foundry and make Solidity **0.8.26** available in its compiler cache.
All test dependencies are vendored as ordinary files under `lib/`; production
contracts have no dependencies. No network is needed once the compiler and
Foundry are installed. No FFI, filesystem cheatcode permissions, environment
variables, keys, RPC endpoint, or fork are required by the delivered tests.

```sh
forge build
forge test
forge fmt --check
```

The configuration pins Solidity 0.8.26, Cancun, optimizer 200 runs, and
`bytecode_hash = "none"`. ABI exports are checked-in JSON arrays:

- [`docs/abi/LaunchToken.json`](docs/abi/LaunchToken.json)
- [`docs/abi/NFTPawnShop.json`](docs/abi/NFTPawnShop.json)

Regenerate after changing public interfaces:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/NFTPawnShop.sol:NFTPawnShop abi --json > docs/abi/NFTPawnShop.json
```

The suite covers token supply/transfers/allowances, CREATE2 factory deployment,
nonpayable constructors, runtime size/opcodes, each loan state and role, invalid
values, repeat actions, repawning, event contents, deadline boundaries, all NFT
callback paths, callback reads, reentrant/reverting ETH receivers, fake ownership,
transfer failures, and unsolicited assets. Stateful runs mix requests, repawning,
funding, repayments, cancellations, defaults, withdrawals, and time changes. An
independent credit model and net deposits must match each account and the shop
balance. Each history is then fully settled and all credits withdrawn to prove
that honest lifecycles leave no ETH behind.

Foundry's heuristic lints may flag deadline comparisons and the reentrancy
modifier's final unlock. Deadlines intentionally use block timestamps. The lock
is acquired before any external interaction; callback tests exercise every shop
entry point. Passing these tests is not an independent security audit.

See [`docs/HANDOFF.md`](docs/HANDOFF.md) for deployment, review, and frontend duties,
and [`docs/ABI.md`](docs/ABI.md) for integration details.
