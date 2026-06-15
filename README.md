# Coffer Marketplace

A **permissionless, non-custodial** secondary marketplace for trading [Coffer Bond NFTs](#what-is-a-coffer-bond-nft). Anyone can sign, fill, or cancel orders, and the contract owner's only powers are fee configuration and sweeping accrued fees. The marketplace never holds user funds or NFTs: assets stay in their owner's wallet until a fill settles through approvals, and the contract's balance carries only accrued protocol fees. Two trading mechanisms are supported: **EIP-712 signed listings** (seller signs off-chain, buyer executes on-chain) and **EIP-712 signed offers** (buyer signs off-chain, seller accepts on-chain). Orders are signed off-chain at no cost and live in an off-chain order book. The taker fills an order on-chain, where the signature is verified at that moment. Both EOA wallets and ERC-1271 contract wallets, such as Safe and ERC-4337 accounts, are supported.

Built with Solidity 0.8.34, [Foundry](https://book.getfoundry.sh/), and OpenZeppelin (`Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `Address`, `EIP712`, `SignatureChecker`).

> **Fee on completed trades only.** A profit-based percentage fee is charged on `buySignedListing` (paid in ETH) and on `acceptSignedOffer` (paid in WETH). Signing a listing or offer costs nothing, and cancelling on-chain costs only gas. Fees accumulate in the contract and are swept to a fee recipient by the contract owner.

---

## What is a Coffer Bond NFT?

A Coffer Bond NFT is an ERC-721 token representing a fixed-income bond from a validator. When a holder sends ETH to a Coffer (validator) contract, they receive an NFT encoding:

- **Maturity value.** The ETH amount owed at maturity.
- **Duration.** The bond term in seconds.
- **Start timestamp.** When the bond was created.

A bond is considered **outstanding** while its `bondMaturityValue != 0`. The marketplace only allows trading outstanding bonds. Bonds may mature, be partially withdrawn, or be early-redeemed by the validator. Any of these can zero out the maturity value and invalidate the bond for trading.

---

## Architecture

> **Enforced by code**: Ownable2Step, ReentrancyGuard, EIP-712 signatures, maturity value binding, two-tier nonce replay protection, CEI pattern, fee slippage protection, fee cap for offers, bond outstanding check.

### Immutables and Constants

| Variable | Type | Description |
|---|---|---|
| `I_WETH` | `address` | WETH token contract |
| `I_COFFER_BOND_NFT` | `address` | CofferBondNft contract |
| `BPS_DENOMINATOR` | `uint16 constant = 10000` | Basis points denominator (100% = 10000) |

### Storage

| Variable | Type | Description |
|---|---|---|
| `sFeeRecipient` | `address` | Current recipient of claimed fees |
| `sListingFeeBps` | `uint16` | buySignedListing profit fee in basis points, paid in ETH |
| `sOfferFeeBps` | `uint16` | acceptSignedOffer profit fee in basis points, paid in WETH |
| `sGlobalListingNonce` | `mapping(address => uint256)` | Global listing nonce per seller (bumped by cancelAllListings) |
| `sListingNonce` | `mapping(address => mapping(uint256 => uint256))` | Per-bond listing nonce per seller (bumped on fill or per-bond cancel) |
| `sGlobalOfferNonce` | `mapping(address => uint256)` | Global offer nonce per buyer (bumped by cancelAllOffers) |
| `sOfferNonce` | `mapping(address => mapping(uint256 => uint256))` | Per-bond offer nonce per buyer (bumped on fill or per-bond cancel) |

### Interfaces

| Interface | Purpose |
|---|---|
| `ICofferBondNft` | The marketplace uses `ownerOf`, `cofferOf`, `isApprovedForAll`, and `safeTransferFrom` |
| `ICoffer` | Query bond conditions via `sHolderConditions`, which gives maturity value, duration, start timestamp, and a consensus flag the marketplace ignores |
| `IWETH` | ERC-20 operations for Wrapped ETH, namely `balanceOf`, `allowance`, `transfer`, `transferFrom`, and `deposit` |

---

## How the Marketplace Works

### Listings (ETH)

1. Seller signs an EIP-712 `Listing(bondId, price, maturityValue, expiration, nonce, globalNonce)` message with their wallet, using the current on-chain per-bond nonce. Signing costs nothing.
2. The signed listing is posted to the off-chain order book. There is no on-chain registration step.
3. Buyer calls `buySignedListing()` passing the listing parameters and the seller's signature. The contract rejects self-trades and a zero price, checks the signed per-bond and global nonces against the current ones, checks the seller still owns the bond and has the marketplace approved, checks the order is unexpired, verifies the signature against the seller, checks the bond is outstanding and that the signed `maturityValue` equals the bond's live maturity value (reverting `MaturityValueMismatch` otherwise), computes the profit-based fee (profit is the maturity value minus the price when positive, fee is `profit * sListingFeeBps / 10000`, and the call reverts `FeeExceedsMax` if the fee exceeds the buyer's `_maxFee` parameter), requires the sent ETH to cover price plus fee, bumps the nonce to prevent replay, and executes the trade. The NFT goes to the buyer, the ETH price goes to the seller (with a WETH deposit and transfer fallback if the seller rejects ETH), the fee stays in the marketplace, and excess ETH is refunded to the buyer.

### Offers (WETH)

1. Buyer signs an EIP-712 `Offer(bondId, wethAmount, maturityValue, expiration, maxFee, nonce, globalNonce)` message at the current on-chain per-bond nonce. The accept reverts if the WETH fee computed at accept time exceeds the signed `maxFee`. Signing costs nothing.
2. The signed offer is posted to the off-chain order book. There is no on-chain registration step and no WETH balance or allowance check until acceptance.
3. Seller calls `acceptSignedOffer()` passing the offer parameters and the buyer's signature. The contract rejects self-trades and a zero amount, checks the signed per-bond and global nonces against the current ones, requires the caller to own the bond and have the marketplace approved, checks the offer is unexpired, verifies the signature against the buyer, checks the bond is outstanding and that the signed `maturityValue` equals the bond's live maturity value (reverting `MaturityValueMismatch` otherwise), recomputes the WETH fee from the current admin config (reverting if it exceeds the signed `maxFee`), bumps the nonce to prevent replay, then verifies the buyer has sufficient WETH balance and allowance and executes the trade. The WETH amount goes from buyer to seller, the WETH fee goes from buyer to the marketplace, and the NFT transfers from seller to buyer.

### Fee Flow

- **ETH fees** accumulate in the marketplace's native balance, exclusively from `buySignedListing`. They are claimed via `claimFees()`.
- **WETH fees** accumulate in the marketplace's WETH balance, exclusively from `acceptSignedOffer`. They are claimed via `claimWethFees()`.
- Both claim functions are `onlyOwner` and send to `sFeeRecipient`.
- Both claim functions sweep the full balance, not a tracked ledger, so any ETH or WETH sent to the contract outside the fee flow is also paid to the fee recipient. Per-trade fees are auditable from the `ListingPurchased` and `OfferAccepted` events.

### Protections (enforced by code)

- **EIP-712 signature integrity.** Every field in a listing or offer is cryptographically bound to the signer. Changing any parameter invalidates the signature, which eliminates the need for `_expectedPrice` and `_expectedAmount` front-running guards. Signatures are verified with OpenZeppelin `SignatureChecker`, so both EOA signatures and ERC-1271 contract-wallet signatures (Safe, ERC-4337) are accepted. Contract-wallet validity is checked at fill time, so a wallet that revokes its authorization after signing correctly fails at the fill.
- **Maturity value binding.** The signed `maturityValue` is re-checked against the bond's live maturity value at fill. If the bond changed after signing, the fill reverts `MaturityValueMismatch`. This binds the committed price to the bond value the maker signed against.
- **Nonce-based replay protection.** Each listing and offer is signed at the current per-bond per-user nonce. After a successful trade, the nonce is auto-incremented, which prevents the same signature from being reused. Cancellation works by bumping the nonce, which renders all previous signatures for that bond invalid.
- **Two-tier nonce system.** Per-bond nonces handle single and batch cancellation. A global nonce per user enables cancel-all, where one transaction invalidates every listing or offer for that user.
- **Fee slippage protection.** buySignedListing takes a `_maxFee` parameter and reverts with `FeeExceedsMax` if the computed fee exceeds it. acceptSignedOffer enforces the buyer-signed `maxFee` the same way, the accept reverts if the recomputed fee exceeds it.
- **Fee cap for offers.** The buyer signs a `maxFee` in the EIP-712 Offer message. At accept time, the fee is recomputed from the current admin config. If it exceeds the signed cap, the transaction reverts. If the admin has lowered fees, the buyer pays the lower amount.
- **CEI pattern.** The per-bond nonce is bumped before any external token or NFT transfers.
- **ReentrancyGuard.** Applied to `buySignedListing` and `acceptSignedOffer`.
- **Bond outstanding check.** Every trade verifies the bond's maturity value is non-zero.
- **Two-step ownership transfer.** `Ownable2Step` prevents accidental transfer to the wrong address. Renouncing ownership is permanently disabled, so the owner role can never be lost and fees can never become permanently unclaimable.

### Restrictions

- **One open order per bond.** The nonce design supports exactly one live order per maker and bond on each side. Pre-signing several consecutive nonces for the same bond arms the next pre-signed order on every fill or cancel, so a cancel can sell at the next pre-signed price. The order book and signing client must enforce signing only at the current on-chain nonce. See Integration Considerations under Cancelling for the recovery procedure.
- **Revocation is on-chain only.** An order is revoked by an on-chain cancel that bumps the nonce. Re-signing an order off-chain at the same nonce does not revoke the previous signature, so to withdraw an order or raise its price a maker cancels on-chain. Short expirations bound how long a stale signature can linger.

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) installed
- Node.js (for [solhint](https://protofire.github.io/solhint/))
- Deployed `CofferBondNft` and `WETH` contracts

---

## Getting Started

```bash
# Compile
forge build

# Lint (format check + solhint)
make lint

# Static analysis
slither .
```

---

## Usage

### Signing orders (EIP-712)

The EIP-712 domain is `name = "CofferMarketplace"`, `version = "3"`, the chain id, and the marketplace address as `verifyingContract`. The contract exposes `eip712Domain()` (EIP-5267), so clients can read the domain at runtime instead of hardcoding it. The two type strings, verbatim from the contract:

```
Listing(uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)
Offer(uint256 bondId,uint128 wethAmount,uint128 maturityValue,uint64 expiration,uint256 maxFee,uint256 nonce,uint256 globalNonce)
```

The signed `maxFee` field of an Offer is passed to `acceptSignedOffer` as the `maxOfferFee` parameter, same value, different name.

The signed `maturityValue` must equal the bond's live maturity (`getBondData(bondId)` returns it) at the moment of signing. It is re-checked on-chain at fill against the live value: if the bond's maturity changed after signing, for example because the holder partially withdrew, the fill reverts `MaturityValueMismatch`. This binds the price the maker committed to the bond value they signed against, so a counterparty cannot collapse the bond and still settle. The order book and signing client must snapshot the current maturity into the order and re-quote and re-sign whenever it changes.

### Selling via Listing

```
1. Seller: cofferBondNft.setApprovalForAll(marketplace, true)
2. Seller: signTypedData(marketplace, Listing(bondId, price, maturityValue, expiration, nonce, globalNonce))   (nonce = current sListingNonce, maturityValue = current getBondData(bondId) maturity)
3. Seller: post the signed listing to the order book (off-chain, no gas)
4. Buyer:  marketplace.buySignedListing(bondId, seller, price, maturityValue, expiration, nonce, globalNonce, maxFee, sig)   {value: price + buyFee}
```

### Selling via Offer

```
1. Buyer:  weth.approve(marketplace, offerAmount + expectedFee)
2. Buyer:  signTypedData(marketplace, Offer(bondId, wethAmount, maturityValue, expiration, maxFee, nonce, globalNonce))   (nonce = current sOfferNonce, maturityValue = current getBondData(bondId) maturity)
3. Buyer:  post the signed offer to the order book (off-chain, no gas)
4. Seller: cofferBondNft.setApprovalForAll(marketplace, true)
5. Seller: marketplace.acceptSignedOffer(bondId, buyer, wethAmount, maturityValue, expiration, maxOfferFee, nonce, globalNonce, sig)
```

Note the WETH allowance on step 1 must cover `offerAmount + the profit-based fee` computed at accept time. That fee can never exceed the signed `maxFee`, the accept reverts instead.

### Cancelling

Cancel one, several, or all listings and offers. Cancelling is free, the caller pays only gas.

```
marketplace.cancelListing(bondId)         (cancel one listing)
marketplace.cancelListings(bondIds[])     (cancel N listings)
marketplace.cancelAllListings()           (cancel all listings)
marketplace.cancelOffer(bondId)           (cancel one offer)
marketplace.cancelOffers(bondIds[])       (cancel N offers)
marketplace.cancelAllOffers()             (cancel all offers)
```

#### Integration Considerations

A fill requires the signed nonce to equal the current on-chain nonce, and every fill or per-bond cancel advances that nonce by exactly one. This gives the integration layer a small set of hard rules.

- **Signing rule.** The client signs only at the current on-chain nonce (`sListingNonce(maker, bondId)` or `sOfferNonce(maker, bondId)`) and keeps at most one open signed order per maker, bond, and side. Never let a maker sign nonce N+1 while their nonce N order is still open. Pre-signing the next nonce means a later cancel or fill arms it at its signed price.
- **Order book rule.** Key orders by (maker, bondId, side, nonce), not by signature bytes, since ERC-1271 contract wallets make signature bytes non-unique. When a second open order arrives for the same maker and bond, reject it or replace the stored one. Re-signing at the same nonce replaces the order in the book but does not revoke the old signature on-chain, both verify, so raising a price requires an on-chain cancel first.
- **Independence of bonds.** Per-bond cancels touch only that bond. A maker with offers on bond A and bond B cancels A with `cancelOffer(A)` and the offer on B stays live. `cancelAllOffers()` kills every offer on every bond for that maker, use it only as the deliberate sweep. Listings behave the same way.
- **Recovery from a pre-signed queue.** If a maker violated the signing rule and pre-signed k consecutive nonces for one bond, a single cancel only advances the nonce by one and arms the next pre-signed order. The backend must clear the whole queue in one transaction by repeating the bond id, for example `cancelListings([A, A])` for k = 2, or the bond id repeated k times in general. The nonce advances past every pre-signed value atomically, with no window in which the next order is fillable, and no other bond is touched. `cancelOffers` works the same for offers.
- **Re-sync after every cancel or fill.** The backend re-reads `sListingNonce`, `sGlobalListingNonce`, `sOfferNonce`, and `sGlobalOfferNonce`, or indexes the cancel and trade events, and drops every stored order whose signed nonces no longer match the chain. The UI then refreshes what it displays as open.

### Risk Factors

- **Pre-signed nonce queues.** Orders signed ahead of the current on-chain nonce arm one by one as fills and cancels advance it. The recovery procedure under Integration Considerations clears the whole queue in one transaction.
- **Stale signatures.** A signed order stays fillable until it expires or the maker cancels on-chain, and re-signing off-chain does not revoke it. Short expirations bound how long a stale signature can linger.
- **Admin fee changes.** The owner can change fee basis points at any time. A fill never pays above the buyer-signed `maxFee` on accept or the `_maxFee` parameter on buy, so a fee raise can make fills revert but can never charge more than the taker agreed to.
- **Bond invalidation after signing.** A bond's maturity value can change after an order is signed, through a partial withdrawal, maturity, or early redemption. Fills against the old value revert `MaturityValueMismatch`, or `BondNotOutstanding` once the value is zeroed, and the order book must re-quote and re-sign against the live value.

### Admin Operations

```
marketplace.setFeeRecipient(newRecipient)
marketplace.setFeeBps(listingFeeBps, offerFeeBps)
marketplace.claimFees()       // sweeps ETH balance to feeRecipient
marketplace.claimWethFees()   // sweeps WETH balance to feeRecipient
marketplace.transferOwnership(newOwner)  // step 1 of Ownable2Step
// newOwner then calls:
marketplace.acceptOwnership()             // step 2 of Ownable2Step
```

### View Functions

- `getBondData(bondId)` returns the maturity value, duration, start timestamp, and coffer address.
- `sGlobalListingNonce(address)` is the global listing nonce for a seller, bumped by cancelAllListings.
- `sListingNonce(address, bondId)` is the per-bond listing nonce for a seller.
- `sGlobalOfferNonce(address)` is the global offer nonce for a buyer, bumped by cancelAllOffers.
- `sOfferNonce(address, bondId)` is the per-bond offer nonce for a buyer.
