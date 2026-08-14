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

    // ──── Ghost State: Nonces (mirrors on-chain nonce state) ────

    // There is no on-chain registration. A maker signs off-chain at the CURRENT on-chain nonce, which
    // the handler models by recording the signed (nonce, globalNonce) pair without any chain call. A
    // listing is "active" (still fillable on-chain) iff:
    //   ghostListingHasOrder[seller][bondId] is true (an order was signed and not consumed)
    //   AND ghostListingSignedNonce[seller][bondId]       == marketplace.sListingNonce(seller, bondId)
    //   AND ghostListingSignedGlobalNonce[seller][bondId] == marketplace.sGlobalListingNonce(seller)
    // The hasOrder flag is needed because the first order for a bond is signed at nonce 0, which a
    // bare "signedNonce > 0" check could not witness. ghostListingNonce / ghostListingGlobalNonce stay
    // plain chain mirrors for the nonce-match invariants (so they ALWAYS equal chain). A fill or a
    // single cancel bumps the per-bond nonce, and cancelAll bumps the global nonce, either of which
    // leaves the signed-* values stale so the listing reads inactive, exactly how the contract's own
    // revoke check works.
    mapping(address => mapping(uint256 => uint256)) public ghostListingNonce;
    mapping(address => uint256) public ghostListingGlobalNonce;
    mapping(address => mapping(uint256 => bool)) public ghostListingHasOrder;
    mapping(address => mapping(uint256 => uint256)) public ghostListingSignedNonce;
    mapping(address => mapping(uint256 => uint256)) public ghostListingSignedGlobalNonce;
    // Track signed price/expiration for buy reconstruction
    mapping(address => mapping(uint256 => uint128)) public ghostListingPrice;
    mapping(address => mapping(uint256 => uint64)) public ghostListingExpiration;

    mapping(address => mapping(uint256 => uint256)) public ghostOfferNonce;
    mapping(address => uint256) public ghostOfferGlobalNonce;
    mapping(address => mapping(uint256 => bool)) public ghostOfferHasOrder;
    // Signed (nonce, globalNonce) pair fixed at signing time; see listing note above.
    mapping(address => mapping(uint256 => uint256)) public ghostOfferSignedNonce;
    mapping(address => mapping(uint256 => uint256)) public ghostOfferSignedGlobalNonce;
    mapping(address => mapping(uint256 => uint128)) public ghostOfferAmount;
    mapping(address => mapping(uint256 => uint64)) public ghostOfferExpiration;
    mapping(address => mapping(uint256 => uint256)) public ghostOfferMaxFee;

    // ──── Ghost State: Bonds ────

    uint256[] public ghostMintedBondIds;
    mapping(uint256 bondId => address owner) public ghostBondOwner;
    mapping(uint256 bondId => bool outstanding) public ghostBondOutstanding;

    // ──── Ghost State: Lifecycle Counters ────

    uint256 public ghostTotalListingsCreated;
    uint256 public ghostTotalListingsCancelled;
    uint256 public ghostTotalListingsPurchased;
    uint256 public ghostTotalListingsRevoked;
    uint256 public ghostTotalOffersMade;
    uint256 public ghostTotalOffersCancelled;
    uint256 public ghostTotalOffersAccepted;
    uint256 public ghostTotalOffersRevoked;

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
        address owner = actors[actorSeed % actors.length];
        uint256 id = bondNft.mintTo(owner, address(coffer));
        coffer.setMaturityValue(id, 1 ether);
        ghostMintedBondIds.push(id);
        ghostBondOwner[id] = owner;
        ghostBondOutstanding[id] = true;
    }

    function handlerSignListing(uint256 actorSeed, uint256 bondSeed, uint128 price, uint64 expOffset) external {
        ++callsSignListing;
        address actor = actors[actorSeed % actors.length];
        uint256 bondId = _findOwnedOutstandingBond(actor, bondSeed);
        if (bondId == 0) return;

        price = uint128(bound(price, 1, 10 ether));
        uint64 expiration = uint64(block.timestamp + bound(expOffset, 1, 365 days));

        // The maker signs off-chain at the current on-chain nonce. No chain call, only ghost state.
        uint256 nonce = marketplace.sListingNonce(actor, bondId);
        uint256 gNonce = marketplace.sGlobalListingNonce(actor);

        ghostListingHasOrder[actor][bondId] = true;
        ghostListingSignedNonce[actor][bondId] = nonce;
        ghostListingSignedGlobalNonce[actor][bondId] = gNonce;
        ghostListingPrice[actor][bondId] = price;
        ghostListingExpiration[actor][bondId] = expiration;
        ++ghostTotalListingsCreated;
    }

    function handlerCancelListing(uint256 actorSeed, uint256 bondSeed) external {
        ++callsCancelListing;
        address actor = actors[actorSeed % actors.length];
        uint256 bondId = _findRegisteredListing(actor, bondSeed);
        if (bondId == 0) return;

        vm.prank(actor);
        marketplace.cancelListing(bondId);

        ghostListingNonce[actor][bondId] = marketplace.sListingNonce(actor, bondId);
        ++ghostTotalListingsCancelled;
    }

    function handlerCancelAllListings(uint256 actorSeed) external {
        ++callsCancelAllListings;
        address actor = actors[actorSeed % actors.length];

        // Count the listings this cancelAll actually invalidates (active under the current global
        // nonce) before bumping it; afterwards their signed global nonce is stale, so they read
        // inactive and can never be resolved again.
        uint256 revoked = _countActiveListings(actor);

        vm.prank(actor);
        marketplace.cancelAllListings();

        ghostListingGlobalNonce[actor] = marketplace.sGlobalListingNonce(actor);
        ghostTotalListingsRevoked += revoked;
    }

    function handlerBuySignedListing(uint256 buyerSeed, uint256 bondSeed) external {
        ++callsBuySignedListing;
        uint256 bondId = _findActiveListedBond(bondSeed);
        if (bondId == 0) return;

        // Find the seller who has an active listing for this bond
        address seller;
        uint128 price;
        uint64 expiration;
        uint256 nonce;
        uint256 gNonce;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            if (
                ghostListingHasOrder[actor][bondId]
                    && ghostListingSignedNonce[actor][bondId] == marketplace.sListingNonce(actor, bondId)
                    && ghostListingSignedGlobalNonce[actor][bondId] == marketplace.sGlobalListingNonce(actor)
            ) {
                seller = actor;
                price = ghostListingPrice[actor][bondId];
                expiration = ghostListingExpiration[actor][bondId];
                nonce = ghostListingSignedNonce[actor][bondId];
                gNonce = ghostListingSignedGlobalNonce[actor][bondId];
                break;
            }
        }
        if (seller == address(0)) return;

        address buyer = _pickActorExcluding(buyerSeed, seller);
        if (buyer == address(0)) return;

        // Pre-flight checks
        if (!ghostBondOutstanding[bondId]) return;
        if (ghostBondOwner[bondId] != seller) return;
        if (buyer.balance < price) return;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > expiration) return;

        // Reconstruct the seller's signature from the listing parameters
        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signListing(actorPk[seller], bondId, price, mat, expiration, nonce, gNonce);

        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, mat, expiration, nonce, gNonce, 0, sig);

        // Nonce auto-incremented by contract
        ghostListingNonce[seller][bondId] = marketplace.sListingNonce(seller, bondId);
        ghostBondOwner[bondId] = buyer;
        ++ghostTotalListingsPurchased;
    }

    function handlerSignOffer(uint256 buyerSeed, uint256 bondSeed, uint128 amount, uint64 expOffset) external {
        ++callsSignOffer;
        if (ghostMintedBondIds.length == 0) return;

        address buyer = actors[buyerSeed % actors.length];
        uint256 bondId = _findOutstandingBond(bondSeed);
        if (bondId == 0) return;

        uint256 wethBal = weth.balanceOf(buyer);
        if (wethBal == 0) return;
        amount = uint128(bound(amount, 1, wethBal));
        uint64 expiration = uint64(block.timestamp + bound(expOffset, 1, 365 days));

        // The offerer signs off-chain at the current on-chain nonce. No chain call, only ghost state.
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        uint256 gNonce = marketplace.sGlobalOfferNonce(buyer);

        ghostOfferHasOrder[buyer][bondId] = true;
        ghostOfferSignedNonce[buyer][bondId] = nonce;
        ghostOfferSignedGlobalNonce[buyer][bondId] = gNonce;
        ghostOfferAmount[buyer][bondId] = amount;
        ghostOfferExpiration[buyer][bondId] = expiration;
        ghostOfferMaxFee[buyer][bondId] = type(uint256).max;
        ++ghostTotalOffersMade;
    }

    function handlerCancelOffer(uint256 actorSeed, uint256 bondSeed) external {
        ++callsCancelOffer;
        address actor = actors[actorSeed % actors.length];
        uint256 bondId = _findRegisteredOffer(actor, bondSeed);
        if (bondId == 0) return;

        vm.prank(actor);
        marketplace.cancelOffer(bondId);

        ghostOfferNonce[actor][bondId] = marketplace.sOfferNonce(actor, bondId);
        ++ghostTotalOffersCancelled;
    }

    function handlerCancelAllOffers(uint256 actorSeed) external {
        ++callsCancelAllOffers;
        address actor = actors[actorSeed % actors.length];

        // Count the offers this cancelAll actually invalidates before bumping the global nonce.
        uint256 revoked = _countActiveOffers(actor);

        vm.prank(actor);
        marketplace.cancelAllOffers();

        ghostOfferGlobalNonce[actor] = marketplace.sGlobalOfferNonce(actor);
        ghostTotalOffersRevoked += revoked;
    }

    function handlerAcceptSignedOffer(uint256 bondSeed) external {
        ++callsAcceptSignedOffer;
        uint256 bondId = _findActiveListedBond(bondSeed);
        if (bondId == 0) return;

        address seller = ghostBondOwner[bondId];
        if (seller == address(0)) return;
        if (!ghostBondOutstanding[bondId]) return;

        // Find an active offer from another actor
        address buyer;
        uint128 amount;
        uint64 expiration;
        uint256 maxFee;
        uint256 nonce;
        uint256 gNonce;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            if (actor == seller) continue;
            if (
                ghostOfferHasOrder[actor][bondId]
                    && ghostOfferSignedNonce[actor][bondId] == marketplace.sOfferNonce(actor, bondId)
                    && ghostOfferSignedGlobalNonce[actor][bondId] == marketplace.sGlobalOfferNonce(actor)
            ) {
                buyer = actor;
                amount = ghostOfferAmount[actor][bondId];
                expiration = ghostOfferExpiration[actor][bondId];
                maxFee = ghostOfferMaxFee[actor][bondId];
                nonce = ghostOfferSignedNonce[actor][bondId];
                gNonce = ghostOfferSignedGlobalNonce[actor][bondId];
                break;
            }
        }
        if (buyer == address(0)) return;

        // Pre-flight checks
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > expiration) return;
        if (weth.balanceOf(buyer) < amount) return;
        if (weth.allowance(buyer, address(marketplace)) < amount) return;
        if (!bondNft.isApprovedForAll(seller, address(marketplace))) return;

        uint128 mat = coffer.maturityValues(bondId);
        bytes memory sig = _signOffer(actorPk[buyer], bondId, amount, mat, expiration, maxFee, nonce, gNonce);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, amount, mat, expiration, maxFee, nonce, gNonce, sig);

        ghostOfferNonce[buyer][bondId] = marketplace.sOfferNonce(buyer, bondId);
        ghostBondOwner[bondId] = buyer;
        ++ghostTotalOffersAccepted;
    }

    function handlerWarpTime(uint256 seconds_) external {
        ++callsWarpTime;
        uint256 advance = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + advance);
    }

    function handlerSetNonOutstanding(uint256 bondSeed) external {
        ++callsSetNonOutstanding;
        if (ghostMintedBondIds.length == 0) return;

        uint256 bondId = ghostMintedBondIds[bondSeed % ghostMintedBondIds.length];
        if (!ghostBondOutstanding[bondId]) return;

        coffer.setMaturityValue(bondId, 0);
        ghostBondOutstanding[bondId] = false;
    }

    function handlerTransferNft(uint256 actorSeed, uint256 bondSeed) external {
        ++callsTransferNft;
        if (ghostMintedBondIds.length == 0) return;

        uint256 bondId = ghostMintedBondIds[bondSeed % ghostMintedBondIds.length];
        address currentOwner = ghostBondOwner[bondId];
        if (currentOwner == address(0)) return;

        address recipient = actors[actorSeed % actors.length];
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
    //                      Internal Helpers
    // ═══════════════════════════════════════════════════════════════

    function _findOwnedOutstandingBond(address owner, uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        if (len == 0) return 0;
        uint256 start = seed % len;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[(start + i) % len];
            if (ghostBondOwner[bondId] == owner && ghostBondOutstanding[bondId]) return bondId;
        }
        return 0;
    }

    function _findOutstandingBond(uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        if (len == 0) return 0;
        uint256 start = seed % len;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[(start + i) % len];
            if (ghostBondOutstanding[bondId]) return bondId;
        }
        return 0;
    }

    function _findRegisteredListing(address actor, uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        if (len == 0) return 0;
        uint256 start = seed % len;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[(start + i) % len];
            if (
                ghostListingHasOrder[actor][bondId]
                    && ghostListingSignedNonce[actor][bondId] == marketplace.sListingNonce(actor, bondId)
                    && ghostListingSignedGlobalNonce[actor][bondId] == marketplace.sGlobalListingNonce(actor)
            ) {
                return bondId;
            }
        }
        return 0;
    }

    function _findActiveListedBond(uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        if (len == 0) return 0;
        uint256 start = seed % len;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[(start + i) % len];
            for (uint256 j; j < actors.length; ++j) {
                address actor = actors[j];
                if (
                    ghostListingSignedNonce[actor][bondId] > 0
                        && ghostListingSignedNonce[actor][bondId] == marketplace.sListingNonce(actor, bondId)
                        && ghostListingSignedGlobalNonce[actor][bondId] == marketplace.sGlobalListingNonce(actor)
                ) {
                    return bondId;
                }
            }
        }
        return 0;
    }

    function _findRegisteredOffer(address actor, uint256 seed) internal view returns (uint256) {
        uint256 len = ghostMintedBondIds.length;
        if (len == 0) return 0;
        uint256 start = seed % len;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[(start + i) % len];
            if (
                ghostOfferHasOrder[actor][bondId]
                    && ghostOfferSignedNonce[actor][bondId] == marketplace.sOfferNonce(actor, bondId)
                    && ghostOfferSignedGlobalNonce[actor][bondId] == marketplace.sGlobalOfferNonce(actor)
            ) {
                return bondId;
            }
        }
        return 0;
    }

    function _countActiveListings(address actor) internal view returns (uint256 count) {
        uint256 len = ghostMintedBondIds.length;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[i];
            if (
                ghostListingHasOrder[actor][bondId]
                    && ghostListingSignedNonce[actor][bondId] == marketplace.sListingNonce(actor, bondId)
                    && ghostListingSignedGlobalNonce[actor][bondId] == marketplace.sGlobalListingNonce(actor)
            ) {
                ++count;
            }
        }
    }

    function _countActiveOffers(address actor) internal view returns (uint256 count) {
        uint256 len = ghostMintedBondIds.length;
        for (uint256 i; i < len; ++i) {
            uint256 bondId = ghostMintedBondIds[i];
            if (
                ghostOfferHasOrder[actor][bondId]
                    && ghostOfferSignedNonce[actor][bondId] == marketplace.sOfferNonce(actor, bondId)
                    && ghostOfferSignedGlobalNonce[actor][bondId] == marketplace.sGlobalOfferNonce(actor)
            ) {
                ++count;
            }
        }
    }

    function _pickActorExcluding(uint256 seed, address exclude) internal view returns (address) {
        uint256 len = actors.length;
        uint256 start = seed % len;
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
