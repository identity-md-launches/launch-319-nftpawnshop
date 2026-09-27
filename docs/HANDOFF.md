# Contract stage handoff

## Concrete deployment parameters

| Parameter | Value |
| --- | --- |
| Network | Sepolia only, chain ID `11155111` |
| Project kind | `evm_project` |
| Site label | `lab-nft-pawnshop` |
| Launch token artifact | `src/LaunchToken.sol:LaunchToken` |
| Token metadata | `Pawn`, `PAWN`, decimals `18`, supply `1000000000000000000000000000` |
| Application list | One contract, identifier `NFTPawnShop` |
| Application artifact | `src/NFTPawnShop.sol:NFTPawnShop` |
| Both constructor argument lists | Empty: `[]` |
| Both constructor values | `0` |
| Solidity | `0.8.26` |
| Compiler settings | Cancun, optimizer enabled / 200 runs, metadata bytecode hash `none` |
| Initialization calls | None |
| Owner/privileged arguments | None |
| Application dependency references | None |
| Initial application ETH / PAWN requirements | None |

The token constructor mints to `msg.sender`, deliberately the project factory.
The shop does not use constructor `msg.sender` and gives the factory no privilege.
The factory can retain and distribute the entire token supply according to policy
without transferring any PAWN to the application. Constructors work via CREATE2
and require neither a precomputed address nor another initialization transaction.

The source is chain-independent Solidity; the Sepolia restriction is an
operational deployment/frontend requirement. No embedded wallet, factory, pool,
or deployed contract address is invented here.

## Responsibilities after source acceptance

1. The **manifest contributor** writes only `launch.json` from accepted artifacts,
   listing LaunchToken and the single application above. Contract identifiers,
   source paths, empty argument lists, supply, and decimals must agree with source.
   There is no `$owner` requirement and no application address dependency.
2. An **independent adversarial reviewer** inspects both source and the completed
   manifest, and returns findings without rewriting source or ABI files. Review
   the deadline second in both transaction orders; callbacks during request,
   cancel, repay, claim, and withdraw; lying ownership; collection transfer
   failures; repeated pawning; and every ETH credit/withdrawal path. The submitted
   tests are implementation validation, not that independent review.
3. **Launch services** select the actual factory and pinned policy, publish source,
   link signed artifacts and attestations, admit, and deploy. Policy/reward and
   signed-artifact linkage belong to services. Concrete source, constructor,
   policy, or authorization conflicts remain review findings. The supplied v5
   guidance describes a 20 ETH opening FDV and 2%/8% contributor rewards; those
   are not token or shop runtime functions. Pool/reward parameters must follow
   the service's pinned policy, not assumptions embedded in these contracts.
4. **Deployment operators** record transaction hashes, chain ID, both addresses,
   the shop deployment block, and the exact accepted artifacts/settings. Confirm
   runtime and ABI against the accepted build and confirm the token minted the
   declared supply to the factory. Persist this data for frontend configuration.
5. The **frontend contributor** builds the one-page static site after deployment,
   with `dist/index.html`, using only views and events. GitHub publication and
   IPFS hosting are approved workflow outcomes handled in that later stage.

No wallet key, broadcast, deployment, publication, or manifest is part of this
source contribution. Later service outcomes are not prerequisites for verifying
these contracts locally.

## Frontend and operator integration

Require chain ID 11155111 before writes. Use the verified deployed addresses and
ABIs, not addresses from tests. Users first approve the individual NFT to the
shop, wait for approval, then call `request`. Parse ETH amounts exactly into wei
without floating-point rounding. Show flat interest, total debt, duration, and
collection trust warning before a lender funds.

Enumerate loan IDs from `loanCount()` and fetch `loan(id)` in bounded batches.
Use Requested/Cancelled/Funded/Repaid/Claimed logs for incremental updates,
querying bounded block chunks starting at the recorded deployment block. Handle
provider range limits, deduplicate by transaction hash/log index, and refresh
views after reorgs and mined writes. There is no backend or indexer requirement.

Expose request, cancel, fund, repay, claim, and withdraw with the restrictions
listed in the README. The displayed countdown is advisory: use the latest block
timestamp and contract state for transaction preparation, and handle transaction
reverts when another action or block wins. Funding and repayment must send the
exact amount; other calls send zero ETH. Repayment may come from any payer, but
always returns the NFT to the recorded borrower. Display credits separately from
loan state; funding/repayment does not deliver ETH until the user withdraws.

Display the README's collection risk text next to **each loan collection address**.
Warn in the request flow against plain transfers to the shop outside `request`.
Contract wallets need to receive ETH and control NFTs received without a hook.
No keepers, price oracle, randomness, liquidator service, or administrative wallet
is required. Claiming after default and withdrawing credits are voluntary user
transactions. Operators cannot rescue unsupported assets or override loan terms.
