# Coffer Marketplace

A secondary marketplace for trading [Coffer Bond NFTs](#what-is-a-coffer-bond-nft). Two trading mechanisms are supported: **ETH listings** (seller sets a price, buyer pays ETH) and **WETH offers** (buyer deposits an offer in WETH, seller accepts).

Built with Solidity ^0.8.33, [Foundry](https://book.getfoundry.sh/), and OpenZeppelin (`Ownable`, `ReentrancyGuard`, `SafeERC20`).

---

## What is a Coffer Bond NFT?

A Coffer Bond NFT is an ERC-721 token representing a fixed-income bond from a validator. When a holder sends ETH to a Coffer (validator) contract, they receive an NFT encoding:

- **Maturity value** — the ETH amount owed at maturity
- **Duration** — the bond term in seconds
- **Start timestamp** — when the bond was created

A bond is considered **outstanding** while its `bondMaturityValue != 0`. The marketplace only allows trading outstanding bonds. Bonds may mature, be partially withdrawn, or be early-redeemed by the validator — any of these can zero out the maturity value and invalidate the bond for trading.

---

## How the Marketplace Works

### Listings (ETH)

1. Seller approves the marketplace and calls `list()` with a price and expiration.
2. Buyer calls `buy()` with ETH covering the price plus fees.
3. The NFT transfers from seller to buyer; ETH goes to the seller.

### Offers (WETH)

1. Buyer approves WETH spending, then calls `makeOffer()` with a WETH amount and expiration.
2. Seller approves the marketplace and calls `acceptOffer()`.
3. WETH is pulled from the buyer and sent to the seller (minus fees); the NFT transfers to the buyer.

### Safety Mechanisms

- **Front-running protection** — `buy()` takes `_expectedPrice` and `acceptOffer()` takes `_expectedAmount`. The transaction reverts if the on-chain value differs.
- **CEI pattern** — state is deleted before any external calls.
- **ReentrancyGuard** — applied to `buy`, `acceptOffer`, and all batch functions.
- **Bond outstanding check** — every trade verifies the bond's maturity value is non-zero.

### Fee System

Each function can have a configurable fee consisting of a **fixed fee** (wei) and a **percentage fee** (basis points). See [Fee System](#fee-system-1) for details.

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

# Run tests (1024 fuzz runs)
forge test

# Coverage report (excludes test/ and script/)
forge coverage --no-match-coverage "^test/|^script/" --report summary

# Lint (format check + solhint)
make lint

# Static analysis
slither .
```

---

## Deployment

### Step 1 — Deploy the marketplace

Set environment variables, then run the deploy script:

```bash
export MARKETPLACE_OWNER=0x...
export FEE_RECIPIENT=0x...
export WETH_ADDRESS=0x...
export BOND_NFT_ADDRESS=0x...

forge script script/DeployCofferMarketplace.s.sol \
  --rpc-url <RPC_URL> --broadcast --verify
```

### Step 2 — Configure fees

```bash
export MARKETPLACE_ADDRESS=0x...   # output from Step 1

forge script script/ConfigureFees.s.sol \
  --rpc-url <RPC_URL> --broadcast
```

Default fee configuration applied by `ConfigureFees.s.sol`:

| Function | Fixed Fee | Percentage Fee |
|---|---|---|
| `list` | 0.001 ETH | 0% |
| `buy` | 0.001 ETH | 1% (100 bps) |
| `makeOffer` | 0.001 ETH | 0% |
| `acceptOffer` | 0 | 1% WETH (100 bps) |

---

## Usage

### Selling via Listing

```
1. Seller: cofferBondNft.setApprovalForAll(marketplace, true)
2. Seller: marketplace.list(bondId, price, expiration)        // + ETH fee
3. Buyer:  marketplace.buy(bondId, expectedPrice)             // + ETH (price + fees)
```

### Selling via Offer

```
1. Buyer:  weth.approve(marketplace, amount)
2. Buyer:  marketplace.makeOffer(bondId, wethAmount, expiration)  // + ETH fee
3. Seller: cofferBondNft.setApprovalForAll(marketplace, true)
4. Seller: marketplace.acceptOffer(bondId, buyer, expectedAmount) // + optional ETH fee
```

### Cancelling

```
marketplace.cancelListing(bondId)
marketplace.cancelOffer(bondId)
```

### Batch Operations

All single operations have batch counterparts for gas-efficient multi-bond transactions:

- `batchList`, `batchBuy`, `batchCancelListings`
- `batchMakeOffers`, `batchCancelOffers`, `batchAcceptOffers`

### View Functions

- `isListingValid(bondId)` — checks listing exists, not expired, seller still owns NFT, bond outstanding
- `isOfferValid(bondId, buyer)` — checks offer exists, not expired, buyer has sufficient WETH balance and allowance
- `getBondData(bondId)` — returns maturity value, duration, start timestamp, coffer address

---

## Function Reference

### Admin (owner only)

| Function | Parameters | Description | Payable | Event |
|---|---|---|---|---|
| `setFeeRecipient` | `address _recipient` | Update fee recipient | No | `FeeRecipientSet` |
| `setFunctionFee` | `bytes4 _selector, uint128 _fixedFee, uint16 _percentageBps` | Set fee config per function selector | No | `FunctionFeeSet` |

### Listings

| Function | Parameters | Modifiers | Description | Payable | Event |
|---|---|---|---|---|---|
| `list` | `uint256 _bondId, uint128 _price, uint64 _expiration` | — | Create listing | Yes | `Listed` |
| `cancelListing` | `uint256 _bondId` | — | Cancel own listing | No | `ListingCancelled` |
| `buy` | `uint256 _bondId, uint128 _expectedPrice` | `nonReentrant` | Purchase listed bond | Yes | `ListingPurchased` |
| `batchList` | `uint256[] _bondIds, uint128[] _prices, uint64[] _expirations` | `nonReentrant` | Batch list | Yes | `Listed` (per bond) |
| `batchCancelListings` | `uint256[] _bondIds` | — | Batch cancel | No | `ListingCancelled` (per bond) |
| `batchBuy` | `uint256[] _bondIds, uint128[] _expectedPrices` | `nonReentrant` | Batch buy | Yes | `ListingPurchased` (per bond) |

### Offers

| Function | Parameters | Modifiers | Description | Payable | Event |
|---|---|---|---|---|---|
| `makeOffer` | `uint256 _bondId, uint128 _wethAmount, uint64 _expiration` | — | Make WETH offer | Yes | `OfferMade` |
| `cancelOffer` | `uint256 _bondId` | — | Cancel own offer | No | `OfferCancelled` |
| `acceptOffer` | `uint256 _bondId, address _buyer, uint128 _expectedAmount` | `nonReentrant` | Accept WETH offer | Yes | `OfferAccepted` |
| `batchMakeOffers` | `uint256[] _bondIds, uint128[] _wethAmounts, uint64[] _expirations` | `nonReentrant` | Batch offers | Yes | `OfferMade` (per bond) |
| `batchCancelOffers` | `uint256[] _bondIds` | — | Batch cancel | No | `OfferCancelled` (per bond) |
| `batchAcceptOffers` | `uint256[] _bondIds, address[] _buyers, uint128[] _expectedAmounts` | `nonReentrant` | Batch accept | Yes | `OfferAccepted` (per bond) |

### Views

| Function | Parameters | Returns | Description |
|---|---|---|---|
| `isListingValid` | `uint256 _bondId` | `bool` | Check listing validity |
| `isOfferValid` | `uint256 _bondId, address _buyer` | `bool` | Check offer validity |
| `getBondData` | `uint256 _bondId` | `uint128 maturityValue, uint32 duration, uint32 startTimestamp, address cofferAddress` | Get bond data from the associated Coffer |

---

## Fee System

Each function selector maps to an optional `FunctionFee`:

```solidity
struct FunctionFee {
    uint128 fixedFee;      // flat fee in wei
    uint16  percentageBps; // percentage in basis points (1% = 100)
}
```

**ETH functions** (`list`, `buy`, `makeOffer`): fees are deducted from `msg.value`.

- For `buy`, the fee is calculated on the total payment: `fee = fixedFee + percentageFee`, `remaining = msg.value - fee`, and `remaining` must cover the listing price.
- For `list` and `makeOffer`, only the fixed fee applies (percentage is on the operational value, which is 0 for these).

**WETH functions** (`acceptOffer`): a percentage fee is deducted from the WETH amount.

- Formula: `fee = fixedFee + (wethAmount * percentageBps / 10000)`
- The seller receives `wethAmount - fee`.

Fees are sent to `sFeeRecipient`. A `FeeCollected` event is emitted for every non-zero fee.

---

## Events

| Event | Parameters | Description |
|---|---|---|
| `FeeRecipientSet` | `address indexed recipient` | Fee recipient updated |
| `FunctionFeeSet` | `bytes4 indexed selector, uint128 indexed fixedFee, uint16 indexed percentageBps` | Per-function fee configured |
| `FeeCollected` | `bytes4 indexed selector, uint256 indexed fee` | Fee collected and sent to recipient |
| `Listed` | `uint256 indexed bondId, address indexed seller, uint128 indexed price, uint64 expiration` | Bond listed for sale |
| `ListingCancelled` | `uint256 indexed bondId, address indexed seller` | Listing cancelled |
| `ListingPurchased` | `uint256 indexed bondId, address indexed buyer, address indexed seller, uint128 price` | Listed bond purchased |
| `OfferMade` | `uint256 indexed bondId, address indexed buyer, uint128 indexed wethAmount, uint64 expiration` | WETH offer made |
| `OfferCancelled` | `uint256 indexed bondId, address indexed buyer` | Offer cancelled |
| `OfferAccepted` | `uint256 indexed bondId, address indexed buyer, address indexed seller, uint128 wethAmount` | Offer accepted by NFT owner |

---

## Errors

| Error | Description |
|---|---|
| `ZeroAddress()` | Address parameter is the zero address |
| `ZeroPrice()` | Listing price must be greater than zero |
| `ZeroAmount()` | WETH offer amount must be greater than zero |
| `InsufficientFee()` | Payment does not cover the required fee |
| `NotSeller()` | Caller is not the listing seller |
| `NotBuyer()` | Caller is not the offer maker |
| `NotOwner()` | Caller does not own the bond NFT |
| `ListingNotFound()` | No active listing exists for the bond |
| `ListingExpired()` | Listing expiration timestamp has passed |
| `OfferNotFound()` | No active offer exists for the bond/buyer pair |
| `OfferExpired()` | Offer expiration timestamp has passed |
| `PriceMismatch()` | Expected price does not match listing price (front-running protection) |
| `AmountMismatch()` | Expected amount does not match offer amount (front-running protection) |
| `BondNotOutstanding()` | Bond maturity value is zero — bond is no longer tradeable |
| `SellerNoLongerOwnsNft()` | Seller no longer holds the bond NFT |
| `MarketplaceNotApproved()` | Seller has not approved the marketplace to transfer the NFT |
| `ExpirationNotInFuture()` | Expiration timestamp must be in the future |
| `CannotBuyOwnListing()` | Buyer cannot purchase their own listing |
| `InsufficientWethBalance()` | Buyer does not have enough WETH |
| `InsufficientWethAllowance()` | Buyer has not approved enough WETH for the marketplace |
| `InsufficientPayment()` | ETH sent does not cover the price plus fees |
| `ArrayLengthMismatch()` | Batch function input arrays have different lengths |

---

## Architecture

### Immutables

| Variable | Type | Description |
|---|---|---|
| `I_WETH` | `address` | WETH token contract |
| `I_COFFER_BOND_NFT` | `address` | CofferBondNft contract |

### Storage

| Variable | Type | Description |
|---|---|---|
| `sFeeRecipient` | `address` | Receives all collected fees |
| `sFunctionFees` | `mapping(bytes4 => FunctionFee)` | Per-function fee configuration |
| `sListings` | `mapping(uint256 => Listing)` | Active listings by bond ID |
| `sOffers` | `mapping(uint256 => mapping(address => Offer))` | Active offers by bond ID and buyer |

### Interfaces

| Interface | Purpose |
|---|---|
| `ICofferBondNft` | Query bond ownership (`ownerOf`), coffer address (`cofferOf`), transfer and approval functions |
| `ICoffer` | Query bond conditions (`sHolderConditions`) — maturity value, duration, start timestamp |
| `IWETH` | ERC-20 operations for Wrapped ETH — `balanceOf`, `allowance`, `transfer`, `transferFrom` |
