// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

// ───── Mocks ─────

contract MockBondNftForHandler {
    mapping(uint256 => address) private _owners;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => address) private _coffers;
    uint256 public sBondIdCounter;

    function mintTo(address to, address coffer) external returns (uint256) {
        uint256 id = ++sBondIdCounter;
        _owners[id] = to;
        _coffers[id] = coffer;
        return id;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ERC721: nonexistent token");
        return owner;
    }

    function cofferOf(uint256 tokenId) external view returns (address) {
        return _coffers[tokenId];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_owners[tokenId] == from, "ERC721: not owner");
        require(msg.sender == from || _operatorApprovals[from][msg.sender], "ERC721: not approved");
        _owners[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "ERC721: unsafe recipient"
            );
        }
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }
}

contract MockCofferForHandler {
    mapping(uint256 => uint128) public maturityValues;
    uint32 public constant DURATION = 86_400;
    uint32 public startTs;

    constructor() {
        startTs = uint32(block.timestamp);
    }

    function sHolderConditions(uint256 bondId) external view returns (uint128, uint32, uint32) {
        return (maturityValues[bondId], DURATION, startTs);
    }

    function setMaturityValue(uint256 bondId, uint128 val) external {
        maturityValues[bondId] = val;
    }
}

contract MockWETHForHandler {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "WETH: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "WETH: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "WETH: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

// ───── Handler ─────

/// @notice Fuzz handler for the invariant suite. Every marketplace call the handler makes either
///         succeeds with asserted settlement postconditions, or is predicted to revert with an
///         exact selector through vm.expectRevert (the "oracle"). The suite runs with
///         fail_on_revert = true, so an unexpected revert, an oracle mismatch or a failed
///         postcondition fails the run with a counterexample. The only silent returns left are
///         handler-universe limits (nothing signed yet, nothing to sign for, handler funds), each
///         counted so a starved path is visible in the afterInvariant summary.
contract CofferMarketplaceHandler is Test {
    // ──── EIP-712 Constants ────

    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant OFFER_TYPEHASH = keccak256(
        "Offer(uint256 bondId,uint128 wethAmount,uint128 maturityValue,uint64 expiration,uint256 maxFee,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // ──── External Contracts ────

    CofferMarketplace public marketplace;
    MockBondNftForHandler public bondNft;
    MockCofferForHandler public coffer;
    MockWETHForHandler public weth;

    // ──── Actors with known private keys ────

    address[] public actors;
    mapping(address => uint256) public actorPk;

    // ──── Order snapshots (memory only, keeps the fill handlers under the stack limit) ────

    struct ListingOrder {
        address seller;
        uint256 bondId;
        uint128 price;
        uint128 maturity;
        uint64 expiration;
        uint256 nonce;
        uint256 globalNonce;
    }

    struct OfferOrder {
        address buyer;
        uint256 bondId;
        uint128 amount;
        uint128 maturity;
        uint64 expiration;
        uint256 maxFee;
        uint256 nonce;
        uint256 globalNonce;
    }

    // ──── Ghost State: Nonces (PREDICTED, never copied from chain) ────

    // ghostListingNonce / ghostListingGlobalNonce are the handler's prediction of the on-chain
    // nonces: bumped by exactly one on a fill or a single cancel (per-bond) and on cancelAll
    // (global). They are never read back from the marketplace, so the nonce-mirror invariants
    // check that the contract advances exactly the predicted key by exactly one, and a mis-bump
    // also surfaces as an oracle mismatch at the next fill attempt in every campaign.
    //
    // There is no on-chain registration. A maker signs off-chain at the CURRENT nonces, which the
    // handler models by recording the signed (nonce, globalNonce, maturity) triple at the
    // predicted values. A listing is "active" (fillable on-chain) iff:
    //   ghostListingHasOrder[seller][bondId]                                          (signed)
    //   AND ghostListingSignedNonce[seller][bondId]       == ghostListingNonce[seller][bondId]
    //   AND ghostListingSignedGlobalNonce[seller][bondId] == ghostListingGlobalNonce[seller]
    // The hasOrder flag is needed because the first order for a bond is signed at nonce 0. A
    // stale order (nonces moved on) is kept on purpose: it is the replay-protection probe the
    // oracle predicts ListingRevoked for. Re-signing the same (seller, bond) overwrites the slot,
    // which mirrors the README's one-open-order-per-bond restriction.
    mapping(address => mapping(uint256 => uint256)) public ghostListingNonce;
    mapping(address => uint256) public ghostListingGlobalNonce;
    mapping(address => mapping(uint256 => bool)) public ghostListingHasOrder;
    mapping(address => mapping(uint256 => uint256)) public ghostListingSignedNonce;
    mapping(address => mapping(uint256 => uint256)) public ghostListingSignedGlobalNonce;
    mapping(address => mapping(uint256 => uint128)) public ghostListingSignedMaturity;
    mapping(address => mapping(uint256 => uint128)) public ghostListingPrice;
    mapping(address => mapping(uint256 => uint64)) public ghostListingExpiration;

    mapping(address => mapping(uint256 => uint256)) public ghostOfferNonce;
    mapping(address => uint256) public ghostOfferGlobalNonce;
    mapping(address => mapping(uint256 => bool)) public ghostOfferHasOrder;
    mapping(address => mapping(uint256 => uint256)) public ghostOfferSignedNonce;
    mapping(address => mapping(uint256 => uint256)) public ghostOfferSignedGlobalNonce;
    mapping(address => mapping(uint256 => uint128)) public ghostOfferSignedMaturity;
    mapping(address => mapping(uint256 => uint128)) public ghostOfferAmount;
    mapping(address => mapping(uint256 => uint64)) public ghostOfferExpiration;
    mapping(address => mapping(uint256 => uint256)) public ghostOfferMaxFee;

    // ──── Ghost State: Bonds ────

    uint256[] public ghostMintedBondIds;
    mapping(uint256 bondId => address owner) public ghostBondOwner;
    mapping(uint256 bondId => bool outstanding) public ghostBondOutstanding;

    // ──── Ghost State: Lifecycle Counters (summary only) ────

    uint256 public ghostTotalListingsCreated;
    uint256 public ghostTotalListingsCancelled;
    uint256 public ghostTotalListingsPurchased;
    uint256 public ghostTotalListingsRevoked;
    uint256 public ghostTotalOffersMade;
    uint256 public ghostTotalOffersCancelled;
    uint256 public ghostTotalOffersAccepted;
    uint256 public ghostTotalOffersRevoked;

    // ──── Ghost State: Oracle outcomes (summary only) ────

    mapping(bytes4 => uint256) public ghostBuyRejectedBySelector;
    mapping(bytes4 => uint256) public ghostAcceptRejectedBySelector;
    uint256 public ghostBuyReplaysRejected;
    uint256 public ghostAcceptReplaysRejected;
    uint256 public skippedBuyNoOrder;
    uint256 public skippedBuyInsufficientEth;
    uint256 public skippedAcceptNoOrder;
    uint256 public skippedCancelAllListingsThrottled;
    uint256 public skippedCancelAllOffersThrottled;

    // ──── Ghost State: Conservation ────

    uint256 public ghostInitialTotalEth;
    uint256 public ghostInitialTotalWeth;

    // ──── Call Counters ────

    uint256 public callsMintBond;
    uint256 public callsSignListing;
    uint256 public callsCancelListing;
    uint256 public callsCancelAllListings;
    uint256 public callsBuySignedListing;
    uint256 public callsSignOffer;
    uint256 public callsCancelOffer;
    uint256 public callsCancelAllOffers;
    uint256 public callsAcceptSignedOffer;
    uint256 public callsWarpTime;
    uint256 public callsSetNonOutstanding;
    uint256 public callsTransferNft;

    // ──── Constructor ────

    constructor(
        CofferMarketplace _marketplace,
        MockBondNftForHandler _bondNft,
        MockCofferForHandler _coffer,
        MockWETHForHandler _weth
    ) {
        marketplace = _marketplace;
        bondNft = _bondNft;
        coffer = _coffer;
        weth = _weth;

        for (uint256 i; i < 5; ++i) {
            uint256 pk = uint256(keccak256(abi.encodePacked("actor", i)));
            address actor = vm.addr(pk);
            actors.push(actor);
            actorPk[actor] = pk;
            vm.deal(actor, 1000 ether);

            vm.prank(actor);
            bondNft.setApprovalForAll(address(marketplace), true);

            weth.mint(actor, 1000 ether);
            vm.prank(actor);
            weth.approve(address(marketplace), type(uint256).max);
        }

        for (uint256 i; i < 5; ++i) {
            address owner = actors[i % actors.length];
            uint256 id = bondNft.mintTo(owner, address(coffer));
            coffer.setMaturityValue(id, 1 ether);
            ghostMintedBondIds.push(id);
            ghostBondOwner[id] = owner;
            ghostBondOutstanding[id] = true;
        }

        ghostInitialTotalEth = _sumEthBalances();
        ghostInitialTotalWeth = _sumWethBalances();
    }

    // ═══════════════════════════════════════════════════════════════
    //                      Handler Functions
    // ═══════════════════════════════════════════════════════════════

    function handlerMintBond(uint256 actorSeed) external {
        ++callsMintBond;
        address owner = _actor(actorSeed);
        uint256 id = bondNft.mintTo(owner, address(coffer));
        coffer.setMaturityValue(id, 1 ether);
        ghostMintedBondIds.push(id);
        ghostBondOwner[id] = owner;
        ghostBondOutstanding[id] = true;
    }

    function handlerSignListing(uint256 actorSeed, uint256 bondSeed, uint128 price, uint64 expOffset) external {
        ++callsSignListing;
        address actor = _actor(actorSeed);
        uint256 bondId = _findOwnedOutstandingBond(actor, bondSeed);
        // Handler-universe limit: the actor owns no outstanding bond to list.
        if (bondId == 0) return;

        price = uint128(bound(price, 1, 10 ether));
        uint64 expiration = uint64(block.timestamp + bound(expOffset, 1, 365 days));

        // The maker signs off-chain at the nonces the handler predicts to be current. No chain call.
        ghostListingHasOrder[actor][bondId] = true;
        ghostListingSignedNonce[actor][bondId] = ghostListingNonce[actor][bondId];
        ghostListingSignedGlobalNonce[actor][bondId] = ghostListingGlobalNonce[actor];
        ghostListingSignedMaturity[actor][bondId] = coffer.maturityValues(bondId);
        ghostListingPrice[actor][bondId] = price;
        ghostListingExpiration[actor][bondId] = expiration;
        ++ghostTotalListingsCreated;
    }

    function handlerCancelListing(uint256 actorSeed, uint256 bondSeed) external {
        ++callsCancelListing;
        address actor = _actor(actorSeed);
        uint256 bondId = _pickListingCancelTarget(actor, bondSeed);
        bool wasActive = _isListingActive(actor, bondId);

        vm.prank(actor);
        marketplace.cancelListing(bondId);

        ++ghostListingNonce[actor][bondId];
        if (wasActive) ++ghostTotalListingsCancelled;
    }

    function handlerCancelAllListings(uint256 actorSeed) external {
        ++callsCancelAllListings;
        uint256 m = _mix(actorSeed);
        if (m % 4 != 0) {
            // Throttle to about one call in four: unthrottled, cancelAll revokes nearly every order
            // before a fill, transfer or expiry can happen to it, and ListingRevoked drowns the rest.
            ++skippedCancelAllListingsThrottled;
            return;
        }
        address actor = actors[(m / 4) % actors.length];

        // Count the listings this cancelAll invalidates before bumping the global nonce.
        uint256 revoked = _countActiveListings(actor);

        vm.prank(actor);
        marketplace.cancelAllListings();

        ++ghostListingGlobalNonce[actor];
        ghostTotalListingsRevoked += revoked;
    }

    function handlerBuySignedListing(uint256 buyerSeed, uint256 orderSeed, uint256 excessSeed) external {
        ++callsBuySignedListing;
        ListingOrder memory o = _findListingOrder(orderSeed);
        if (o.seller == address(0)) {
            // Handler-universe limit: nothing has been signed yet.
            ++skippedBuyNoOrder;
            return;
        }

        // Every 8th seed the seller tries to fill its own listing, which the contract rejects first.
        uint256 m = _mix(buyerSeed);
        address buyer = m % 8 == 0 ? o.seller : _pickActorExcluding(m / 8, o.seller);
        uint256 fee = _listingFee(o.maturity, o.price);
        // Overpay by a fuzzed excess so the refund leg is exercised on every successful fill.
        uint256 total = uint256(o.price) + fee + bound(excessSeed, 0, 1 ether);
        if (buyer.balance < total) {
            // Handler-universe limit (1000 ETH per actor, price <= 10 ETH, <= depth fills per run).
            // An ETH shortfall would surface as an empty-data call failure the oracle cannot name.
            ++skippedBuyInsufficientEth;
            return;
        }

        _attemptBuy(o, buyer, fee, total);
    }

    function handlerSignOffer(uint256 buyerSeed, uint256 bondSeed, uint128 amount, uint64 expOffset) external {
        ++callsSignOffer;
        address buyer = _actor(buyerSeed);
        uint256 bondId = _findOutstandingBond(bondSeed);
        // Handler-universe limit: no outstanding bond to bid on.
        if (bondId == 0) return;

        uint256 wethBal = weth.balanceOf(buyer);
        // Handler-universe limit: the offerer has no WETH left to commit.
        if (wethBal == 0) return;
        amount = uint128(bound(amount, 1, wethBal));
        uint64 expiration = uint64(block.timestamp + bound(expOffset, 1, 365 days));

        // The offerer signs off-chain at the predicted nonces. An offerer may sign against its own
        // bond (the order book cannot stop that) and the accept path then rejects with SameParty.
        ghostOfferHasOrder[buyer][bondId] = true;
        ghostOfferSignedNonce[buyer][bondId] = ghostOfferNonce[buyer][bondId];
        ghostOfferSignedGlobalNonce[buyer][bondId] = ghostOfferGlobalNonce[buyer];
        ghostOfferSignedMaturity[buyer][bondId] = coffer.maturityValues(bondId);
        ghostOfferAmount[buyer][bondId] = amount;
        ghostOfferExpiration[buyer][bondId] = expiration;
        ghostOfferMaxFee[buyer][bondId] = type(uint256).max;
        ++ghostTotalOffersMade;
    }

    function handlerCancelOffer(uint256 actorSeed, uint256 bondSeed) external {
        ++callsCancelOffer;
        address actor = _actor(actorSeed);
        uint256 bondId = _pickOfferCancelTarget(actor, bondSeed);
        bool wasActive = _isOfferActive(actor, bondId);

        vm.prank(actor);
        marketplace.cancelOffer(bondId);

        ++ghostOfferNonce[actor][bondId];
        if (wasActive) ++ghostTotalOffersCancelled;
    }

    function handlerCancelAllOffers(uint256 actorSeed) external {
        ++callsCancelAllOffers;
        uint256 m = _mix(actorSeed);
        if (m % 4 != 0) {
            // Throttle, see handlerCancelAllListings.
            ++skippedCancelAllOffersThrottled;
            return;
        }
        address actor = actors[(m / 4) % actors.length];

        // Count the offers this cancelAll invalidates before bumping the global nonce.
        uint256 revoked = _countActiveOffers(actor);

        vm.prank(actor);
        marketplace.cancelAllOffers();

        ++ghostOfferGlobalNonce[actor];
        ghostTotalOffersRevoked += revoked;
    }

    function handlerAcceptSignedOffer(uint256 callerSeed, uint256 orderSeed) external {
        ++callsAcceptSignedOffer;
        OfferOrder memory o = _findOfferOrder(orderSeed);
        if (o.buyer == address(0)) {
            // Handler-universe limit: nothing has been signed yet.
            ++skippedAcceptNoOrder;
            return;
        }

        // The owner accepts, except every 4th seed an arbitrary actor tries, which exercises the
        // SameParty (caller is the offerer) and NotOwner rejections in the contract's check order.
        uint256 m = _mix(callerSeed);
        address caller = m % 4 == 0 ? actors[(m / 4) % actors.length] : ghostBondOwner[o.bondId];

        _attemptAccept(o, caller);
    }

    function handlerWarpTime(uint256 seconds_) external {
        ++callsWarpTime;
        uint256 advance = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + advance);
    }

    function handlerSetNonOutstanding(uint256 bondSeed) external {
        ++callsSetNonOutstanding;
        uint256 bondId = ghostMintedBondIds[_mix(bondSeed) % ghostMintedBondIds.length];
        if (!ghostBondOutstanding[bondId]) return;

        coffer.setMaturityValue(bondId, 0);
        ghostBondOutstanding[bondId] = false;
    }

    function handlerTransferNft(uint256 actorSeed, uint256 bondSeed) external {
        ++callsTransferNft;
        uint256 bondId = ghostMintedBondIds[_mix(bondSeed) % ghostMintedBondIds.length];
        address currentOwner = ghostBondOwner[bondId];

        address recipient = _actor(actorSeed);
        if (recipient == currentOwner) return;

        vm.prank(currentOwner);
        bondNft.transferFrom(currentOwner, recipient, bondId);
        ghostBondOwner[bondId] = recipient;
    }

    // ═══════════════════════════════════════════════════════════════
    //                       View Accessors
    // ═══════════════════════════════════════════════════════════════

    function getMintedBondCount() external view returns (uint256) {
        return ghostMintedBondIds.length;
    }

    function getMintedBondIdAt(uint256 index) external view returns (uint256) {
        return ghostMintedBondIds[index];
    }

    function getActorsLength() external view returns (uint256) {
        return actors.length;
    }

    function getActorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    // ═══════════════════════════════════════════════════════════════
    //                 Internal: Fill attempts and oracle
    // ═══════════════════════════════════════════════════════════════

    /// @dev Attempt a fill of listing `o` by `buyer`. Either the oracle names the revert and the
    ///      call must revert with exactly that selector, or the call must succeed and settle
    ///      exactly, after which the identical replay must be rejected on the nonce check.
    function _attemptBuy(ListingOrder memory o, address buyer, uint256 fee, uint256 total) internal {
        bytes memory sig =
            _signListing(actorPk[o.seller], o.bondId, o.price, o.maturity, o.expiration, o.nonce, o.globalNonce);

        bytes4 expected = _expectedBuyRevert(o, buyer);
        if (expected != bytes4(0)) {
            vm.prank(buyer);
            vm.expectRevert(expected, address(marketplace));
            _callBuy(o, total, fee, sig);
            ++ghostBuyRejectedBySelector[expected];
            return;
        }

        uint256 sellerBefore = o.seller.balance;
        uint256 buyerBefore = buyer.balance;
        uint256 marketBefore = address(marketplace).balance;

        vm.prank(buyer);
        _callBuy(o, total, fee, sig);

        _assertBuySettled(o, buyer, fee, sellerBefore, buyerBefore, marketBefore);

        ++ghostListingNonce[o.seller][o.bondId];
        ghostBondOwner[o.bondId] = buyer;
        ++ghostTotalListingsPurchased;

        // The consumed signature must be dead: an identical replay fails on the nonce check.
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector, address(marketplace));
        _callBuy(o, total, fee, sig);
        ++ghostBuyReplaysRejected;
    }

    /// @dev Mirrors the require order of buySignedListing after dropping the checks the handler
    ///      universe cannot trigger (ZeroPrice, MarketplaceNotApproved, InvalidSignature,
    ///      FeeExceedsMax, InsufficientPayment). Returns 0 when the fill must succeed.
    function _expectedBuyRevert(ListingOrder memory o, address buyer) internal view returns (bytes4) {
        if (buyer == o.seller) return CofferMarketplace.SameParty.selector;
        if (o.nonce != ghostListingNonce[o.seller][o.bondId]) return CofferMarketplace.ListingRevoked.selector;
        if (o.globalNonce != ghostListingGlobalNonce[o.seller]) return CofferMarketplace.ListingRevoked.selector;
        if (ghostBondOwner[o.bondId] != o.seller) return CofferMarketplace.SellerNoLongerOwnsNft.selector;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > o.expiration) return CofferMarketplace.ExpirationNotInFuture.selector;
        uint128 live = coffer.maturityValues(o.bondId);
        if (live == 0) return CofferMarketplace.BondNotOutstanding.selector;
        if (live != o.maturity) return CofferMarketplace.MaturityValueMismatch.selector;
        return bytes4(0);
    }

    function _callBuy(ListingOrder memory o, uint256 value, uint256 maxFee, bytes memory sig) internal {
        marketplace.buySignedListing{value: value}(
            o.bondId, o.seller, o.price, o.maturity, o.expiration, o.nonce, o.globalNonce, maxFee, sig
        );
    }

    function _assertBuySettled(
        ListingOrder memory o,
        address buyer,
        uint256 fee,
        uint256 sellerBefore,
        uint256 buyerBefore,
        uint256 marketBefore
    ) internal view {
        assertEq(bondNft.ownerOf(o.bondId), buyer, "buy: NFT not delivered to buyer");
        assertEq(o.seller.balance, sellerBefore + o.price, "buy: seller not paid exactly price");
        assertEq(buyer.balance, buyerBefore - o.price - fee, "buy: buyer charged other than price + fee");
        assertEq(address(marketplace).balance, marketBefore + fee, "buy: marketplace balance moved by other than fee");
        assertEq(marketplace.sListingNonce(o.seller, o.bondId), o.nonce + 1, "buy: nonce not consumed by exactly one");
        assertEq(marketplace.sGlobalListingNonce(o.seller), o.globalNonce, "buy: global nonce changed by a fill");
    }

    /// @dev Attempt an accept of offer `o` by `caller`. Same contract as _attemptBuy.
    function _attemptAccept(OfferOrder memory o, address caller) internal {
        uint256 fee = _offerFee(o.maturity, o.amount);
        bytes memory sig = _signOffer(
            actorPk[o.buyer], o.bondId, o.amount, o.maturity, o.expiration, o.maxFee, o.nonce, o.globalNonce
        );

        bytes4 expected = _expectedAcceptRevert(o, caller, fee);
        if (expected != bytes4(0)) {
            vm.prank(caller);
            vm.expectRevert(expected, address(marketplace));
            _callAccept(o, sig);
            ++ghostAcceptRejectedBySelector[expected];
            return;
        }

        uint256 callerBefore = weth.balanceOf(caller);
        uint256 buyerBefore = weth.balanceOf(o.buyer);
        uint256 marketBefore = weth.balanceOf(address(marketplace));

        vm.prank(caller);
        _callAccept(o, sig);

        _assertAcceptSettled(o, caller, fee, callerBefore, buyerBefore, marketBefore);

        ++ghostOfferNonce[o.buyer][o.bondId];
        ghostBondOwner[o.bondId] = o.buyer;
        ++ghostTotalOffersAccepted;

        // The consumed signature must be dead: the (now former) owner replays and fails on the nonce.
        vm.prank(caller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector, address(marketplace));
        _callAccept(o, sig);
        ++ghostAcceptReplaysRejected;
    }

    /// @dev Mirrors the require order of acceptSignedOffer after dropping the checks the handler
    ///      universe cannot trigger (ZeroAmount, MarketplaceNotApproved, InvalidSignature).
    ///      `fee` is what the contract charges once the maturity checks pass, so it is only
    ///      relevant to the balance and allowance checks that follow them.
    function _expectedAcceptRevert(OfferOrder memory o, address caller, uint256 fee) internal view returns (bytes4) {
        if (caller == o.buyer) return CofferMarketplace.SameParty.selector;
        if (o.nonce != ghostOfferNonce[o.buyer][o.bondId]) return CofferMarketplace.OfferRevoked.selector;
        if (o.globalNonce != ghostOfferGlobalNonce[o.buyer]) return CofferMarketplace.OfferRevoked.selector;
        if (ghostBondOwner[o.bondId] != caller) return CofferMarketplace.NotOwner.selector;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > o.expiration) return CofferMarketplace.ExpirationNotInFuture.selector;
        uint128 live = coffer.maturityValues(o.bondId);
        if (live == 0) return CofferMarketplace.BondNotOutstanding.selector;
        if (live != o.maturity) return CofferMarketplace.MaturityValueMismatch.selector;
        if (fee > o.maxFee) return CofferMarketplace.FeeExceedsMax.selector;
        uint256 totalWeth = uint256(o.amount) + fee;
        if (weth.balanceOf(o.buyer) < totalWeth) return CofferMarketplace.InsufficientPayment.selector;
        // The mock decrements the allowance on every transferFrom (real WETH short-circuits an
        // infinite approval), so read it live rather than assuming the constructor's max approval.
        if (weth.allowance(o.buyer, address(marketplace)) < totalWeth) {
            return CofferMarketplace.InsufficientPayment.selector;
        }
        return bytes4(0);
    }

    function _callAccept(OfferOrder memory o, bytes memory sig) internal {
        marketplace.acceptSignedOffer(
            o.bondId, o.buyer, o.amount, o.maturity, o.expiration, o.maxFee, o.nonce, o.globalNonce, sig
        );
    }

    function _assertAcceptSettled(
        OfferOrder memory o,
        address caller,
        uint256 fee,
        uint256 callerBefore,
        uint256 buyerBefore,
        uint256 marketBefore
    ) internal view {
        assertEq(bondNft.ownerOf(o.bondId), o.buyer, "accept: NFT not delivered to offerer");
        assertEq(weth.balanceOf(caller), callerBefore + o.amount, "accept: seller not paid exactly amount");
        assertEq(
            weth.balanceOf(o.buyer), buyerBefore - o.amount - fee, "accept: offerer charged other than amount + fee"
        );
        assertEq(
            weth.balanceOf(address(marketplace)), marketBefore + fee, "accept: marketplace WETH moved by other than fee"
        );
        assertEq(marketplace.sOfferNonce(o.buyer, o.bondId), o.nonce + 1, "accept: nonce not consumed by exactly one");
        assertEq(marketplace.sGlobalOfferNonce(o.buyer), o.globalNonce, "accept: global nonce changed by a fill");
    }

    // ═══════════════════════════════════════════════════════════════
    //                      Internal: Fee math
    // ═══════════════════════════════════════════════════════════════

    /// @dev Same formula as CofferMarketplace._feeOnProfit, from the live listing bps, so the
    ///      settlement expectations stay exact once fees are switched on.
    function _listingFee(uint128 maturity, uint128 price) internal view returns (uint256) {
        uint256 profit = maturity > price ? uint256(maturity) - uint256(price) : 0;
        return (profit * uint256(marketplace.sListingFeeBps())) / uint256(marketplace.BPS_DENOMINATOR());
    }

    function _offerFee(uint128 maturity, uint128 amount) internal view returns (uint256) {
        uint256 revenue = maturity > amount ? uint256(maturity) - uint256(amount) : 0;
        return (revenue * uint256(marketplace.sOfferFeeBps())) / uint256(marketplace.BPS_DENOMINATOR());
    }

    // ═══════════════════════════════════════════════════════════════
    //                      Internal: Order lookup
    // ═══════════════════════════════════════════════════════════════

    /// @dev The fuzzer over-samples edge and dictionary values (0, 1, max, words seen in storage), so a
    ///      raw `seed % n` branch fires far more often than one time in n. Hashing first spreads it.
    function _mix(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed)));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[_mix(seed) % actors.length];
    }

    function _isListingActive(address actor, uint256 bondId) internal view returns (bool) {
        return ghostListingHasOrder[actor][bondId]
            && ghostListingSignedNonce[actor][bondId] == ghostListingNonce[actor][bondId]
            && ghostListingSignedGlobalNonce[actor][bondId] == ghostListingGlobalNonce[actor];
    }

    function _isOfferActive(address actor, uint256 bondId) internal view returns (bool) {
        return ghostOfferHasOrder[actor][bondId]
            && ghostOfferSignedNonce[actor][bondId] == ghostOfferNonce[actor][bondId]
            && ghostOfferSignedGlobalNonce[actor][bondId] == ghostOfferGlobalNonce[actor];
    }

    /// @dev A (seller, bond) pair holding a signed listing. Three seeds in four look for an ACTIVE
    ///      order first (fills are the most informative events: settlement postconditions plus a
    ///      replay probe); otherwise, or when none is active, any signed order qualifies, including
    ///      stale ones, which are the ListingRevoked probes. Empty struct (seller == 0) when nothing
    ///      has been signed yet.
    function _findListingOrder(uint256 seed) internal view returns (ListingOrder memory o) {
        uint256 m = _mix(seed);
        (address seller, uint256 bondId) = _scanListingOrders(m / 4, m % 4 != 0);
        if (seller == address(0) && m % 4 != 0) (seller, bondId) = _scanListingOrders(m / 4, false);
        if (seller == address(0)) return o;
        return ListingOrder({
            seller: seller,
            bondId: bondId,
            price: ghostListingPrice[seller][bondId],
            maturity: ghostListingSignedMaturity[seller][bondId],
            expiration: ghostListingExpiration[seller][bondId],
            nonce: ghostListingSignedNonce[seller][bondId],
            globalNonce: ghostListingSignedGlobalNonce[seller][bondId]
        });
    }

    function _scanListingOrders(uint256 start, bool activeOnly) internal view returns (address, uint256) {
        uint256 numActors = actors.length;
        uint256 total = ghostMintedBondIds.length * numActors;
        for (uint256 i; i < total; ++i) {
            uint256 idx = (start + i) % total;
            uint256 bondId = ghostMintedBondIds[idx / numActors];
            address actor = actors[idx % numActors];
            bool hit = activeOnly ? _isListingActive(actor, bondId) : ghostListingHasOrder[actor][bondId];
            if (hit) return (actor, bondId);
        }
        return (address(0), 0);
    }

    /// @dev Offer-side twin of _findListingOrder.
    function _findOfferOrder(uint256 seed) internal view returns (OfferOrder memory o) {
        uint256 m = _mix(seed);
        (address buyer, uint256 bondId) = _scanOfferOrders(m / 4, m % 4 != 0);
        if (buyer == address(0) && m % 4 != 0) (buyer, bondId) = _scanOfferOrders(m / 4, false);
        if (buyer == address(0)) return o;
        return OfferOrder({
            buyer: buyer,
            bondId: bondId,
            amount: ghostOfferAmount[buyer][bondId],
            maturity: ghostOfferSignedMaturity[buyer][bondId],
            expiration: ghostOfferExpiration[buyer][bondId],
            maxFee: ghostOfferMaxFee[buyer][bondId],
            nonce: ghostOfferSignedNonce[buyer][bondId],
            globalNonce: ghostOfferSignedGlobalNonce[buyer][bondId]
        });
    }

    function _scanOfferOrders(uint256 start, bool activeOnly) internal view returns (address, uint256) {
        uint256 numActors = actors.length;
        uint256 total = ghostMintedBondIds.length * numActors;
        for (uint256 i; i < total; ++i) {
            uint256 idx = (start + i) % total;
            uint256 bondId = ghostMintedBondIds[idx / numActors];
            address actor = actors[idx % numActors];
            bool hit = activeOnly ? _isOfferActive(actor, bondId) : ghostOfferHasOrder[actor][bondId];
            if (hit) return (actor, bondId);
        }
        return (address(0), 0);
    }

    /// @dev Any minted bond is a legal cancel target (the contract bumps a nonce with nothing
    ///      signed). Even seeds prefer one of the actor's active orders so the cancel-revokes-order
    ///      path stays frequent; every returned id is one the mirror invariants iterate.
    function _pickListingCancelTarget(address actor, uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        uint256 m = _mix(seed);
        if (m % 2 == 0) {
            uint256 start = (m / 2) % len;
            for (uint256 i; i < len; ++i) {
                uint256 bondId = ghostMintedBondIds[(start + i) % len];
                if (_isListingActive(actor, bondId)) return bondId;
            }
        }
        return ghostMintedBondIds[(m / 2) % len];
    }

    function _pickOfferCancelTarget(address actor, uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        uint256 m = _mix(seed);
        if (m % 2 == 0) {
            uint256 start = (m / 2) % len;
            for (uint256 i; i < len; ++i) {
                uint256 bondId = ghostMintedBondIds[(start + i) % len];
                if (_isOfferActive(actor, bondId)) return bondId;
            }
        }
        return ghostMintedBondIds[(m / 2) % len];
    }

    function _findOwnedOutstandingBond(address owner, uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        uint256 start = _mix(seed) % len;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[(start + i) % len];
            if (ghostBondOwner[bondId] == owner && ghostBondOutstanding[bondId]) return bondId;
        }
        return 0;
    }

    function _findOutstandingBond(uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        uint256 start = _mix(seed) % len;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[(start + i) % len];
            if (ghostBondOutstanding[bondId]) return bondId;
        }
        return 0;
    }

    function _countActiveListings(address actor) internal view returns (uint256 count) {
        uint256 len = ghostMintedBondIds.length;
        for (uint256 i; i < len; ++i) {
            if (_isListingActive(actor, ghostMintedBondIds[i])) ++count;
        }
    }

    function _countActiveOffers(address actor) internal view returns (uint256 count) {
        uint256 len = ghostMintedBondIds.length;
        for (uint256 i; i < len; ++i) {
            if (_isOfferActive(actor, ghostMintedBondIds[i])) ++count;
        }
    }

    function _pickActorExcluding(uint256 seed, address exclude) internal view returns (address) {
        uint256 len = actors.length;
        uint256 start = _mix(seed) % len;
        for (uint256 i; i < len; ++i) {
            address candidate = actors[(start + i) % len];
            if (candidate != exclude) return candidate;
        }
        return address(0);
    }

    function _sumEthBalances() internal view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += actors[i].balance;
        }
        total += address(marketplace).balance;
    }

    function _sumWethBalances() internal view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += weth.balanceOf(actors[i]);
        }
        total += weth.balanceOf(address(marketplace));
    }

    // ═══════════════════════════════════════════════════════════════
    //                      EIP-712 Helpers
    // ═══════════════════════════════════════════════════════════════

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("CofferMarketplace")),
                keccak256(bytes("3")),
                block.chainid,
                address(marketplace)
            )
        );
    }

    function _listingDigest(uint256 bId, uint128 pr, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(LISTING_TYPEHASH, bId, pr, mat, exp, nonce, gNonce));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _offerDigest(
        uint256 bId,
        uint128 wAmt,
        uint128 mat,
        uint64 exp,
        uint256 maxF,
        uint256 nonce,
        uint256 gNonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, bId, wAmt, mat, exp, maxF, nonce, gNonce));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signListing(uint256 pk, uint256 bId, uint128 pr, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _listingDigest(bId, pr, mat, exp, nonce, gNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(
        uint256 pk,
        uint256 bId,
        uint128 wAmt,
        uint128 mat,
        uint64 exp,
        uint256 maxF,
        uint256 nonce,
        uint256 gNonce
    ) internal view returns (bytes memory) {
        bytes32 digest = _offerDigest(bId, wAmt, mat, exp, maxF, nonce, gNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
