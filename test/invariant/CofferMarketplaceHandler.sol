// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

// ───── Mocks (per-bond maturity, needed for invariant testing) ─────

/// @dev Minimal ERC721 mock with cofferOf support
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

/// @dev Per-bond maturity values (unit test mock uses a single global value)
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

/// @dev Minimal ERC-20 mock with mint
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

/// @title CofferMarketplaceHandler
/// @notice Stateful fuzz handler for CofferMarketplace invariant tests.
///         Ghost state mirrors on-chain state for invariant verification.
contract CofferMarketplaceHandler is Test {
    // ───── External Contracts ─────

    CofferMarketplace public marketplace;
    MockBondNftForHandler public bondNft;
    MockCofferForHandler public coffer;
    MockWETHForHandler public weth;

    // ───── Actors (every actor can be both buyer and seller) ─────

    address[] public actors;

    // ───── Ghost State: Listings (keyed by bondId) ─────

    uint256[] public ghostActiveListingBondIds;
    mapping(uint256 bondId => bool) public ghostHasActiveListing;
    mapping(uint256 bondId => uint256 arrayIndex) internal _ghostListingIdx;
    mapping(uint256 bondId => address seller) public ghostListingSeller;
    mapping(uint256 bondId => uint128 price) public ghostListingPrice;

    // ───── Ghost State: Offers (keyed by bondId + buyer) ─────

    struct GhostOfferKey {
        uint256 bondId;
        address buyer;
    }

    GhostOfferKey[] internal _ghostActiveOfferKeys;
    mapping(bytes32 key => bool) public ghostHasActiveOffer;
    mapping(bytes32 key => uint256 arrayIndex) internal _ghostOfferIdx;
    mapping(bytes32 key => uint128 amount) public ghostOfferAmount;

    // ───── Ghost State: Bonds ─────

    uint256[] public ghostMintedBondIds;
    mapping(uint256 bondId => address owner) public ghostBondOwner;
    mapping(uint256 bondId => bool outstanding) public ghostBondOutstanding;

    // ───── Ghost State: Lifecycle Counters ─────

    uint256 public ghostTotalListingsCreated;
    uint256 public ghostTotalListingsCancelled;
    uint256 public ghostTotalListingsPurchased;
    uint256 public ghostTotalListingsInvalidated;
    uint256 public ghostTotalOffersMade;
    uint256 public ghostTotalOffersCancelled;
    uint256 public ghostTotalOffersAccepted;
    uint256 public ghostTotalOffersInvalidated;

    // ───── Ghost State: Conservation ─────

    uint256 public ghostInitialTotalEth;
    uint256 public ghostInitialTotalWeth;

    // ───── Call Counters (debug) ─────

    uint256 public callsMintBond;
    uint256 public callsList;
    uint256 public callsCancelListing;
    uint256 public callsBuy;
    uint256 public callsMakeOffer;
    uint256 public callsCancelOffer;
    uint256 public callsAcceptOffer;
    uint256 public callsWarpTime;
    uint256 public callsSetNonOutstanding;
    uint256 public callsTransferNft;

    // ───── Constructor ─────

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

        // Create 5 actors — each can act as both buyer and seller
        for (uint256 i; i < 5; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            vm.deal(actor, 1000 ether);

            // Approve marketplace for NFT transfers (seller side)
            vm.prank(actor);
            bondNft.setApprovalForAll(address(marketplace), true);

            // Mint WETH and approve marketplace (buyer side)
            weth.mint(actor, 1000 ether);
            vm.prank(actor);
            weth.approve(address(marketplace), type(uint256).max);
        }

        // Pre-mint 5 bonds distributed across actors
        for (uint256 i; i < 5; ++i) {
            address owner = actors[i % actors.length];
            uint256 bondId = bondNft.mintTo(owner, address(coffer));
            coffer.setMaturityValue(bondId, 1 ether);
            ghostMintedBondIds.push(bondId);
            ghostBondOwner[bondId] = owner;
            ghostBondOutstanding[bondId] = true;
        }

        ghostInitialTotalEth = _sumEthBalances();
        ghostInitialTotalWeth = _sumWethBalances();
    }

    // ═══════════════════════════════════════════════════════════════
    //                      Handler Functions
    // ═══════════════════════════════════════════════════════════════

    /// @notice Mint a new bond to a random actor
    function handlerMintBond(uint256 actorSeed) external {
        ++callsMintBond;

        address owner = actors[actorSeed % actors.length];
        uint256 bondId = bondNft.mintTo(owner, address(coffer));
        coffer.setMaturityValue(bondId, 1 ether);

        ghostMintedBondIds.push(bondId);
        ghostBondOwner[bondId] = owner;
        ghostBondOutstanding[bondId] = true;
    }

    /// @notice List an outstanding bond owned by a random actor
    function handlerList(uint256 actorSeed, uint256 bondSeed, uint128 price, uint64 expOffset) external {
        ++callsList;

        address actor = actors[actorSeed % actors.length];
        uint256 bondId = _findOwnedOutstandingBond(actor, bondSeed);
        if (bondId == 0) return;

        price = uint128(bound(price, 1, 10 ether));
        uint64 expiration = uint64(block.timestamp + bound(expOffset, 1, 365 days));

        vm.prank(actor);
        marketplace.list(bondId, price, expiration, 0);

        // New listing or overwrite (marketplace allows overwriting)
        if (ghostHasActiveListing[bondId]) {
            ++ghostTotalListingsInvalidated; // old listing replaced
        } else {
            _ghostListingIdx[bondId] = ghostActiveListingBondIds.length;
            ghostActiveListingBondIds.push(bondId);
            ghostHasActiveListing[bondId] = true;
        }
        ghostListingSeller[bondId] = actor;
        ghostListingPrice[bondId] = price;
        ++ghostTotalListingsCreated;
    }

    /// @notice Cancel a random active listing
    function handlerCancelListing(uint256 listingSeed) external {
        ++callsCancelListing;
        uint256 len = ghostActiveListingBondIds.length;
        if (len == 0) return;

        uint256 idx = listingSeed % len;
        uint256 bondId = ghostActiveListingBondIds[idx];
        address seller = ghostListingSeller[bondId];

        vm.prank(seller);
        marketplace.cancelListing(bondId, 0);

        _removeListingFromGhost(bondId, idx);
        ++ghostTotalListingsCancelled;
    }

    /// @notice Buy a random active listing
    function handlerBuy(uint256 buyerSeed, uint256 listingSeed) external {
        ++callsBuy;
        uint256 len = ghostActiveListingBondIds.length;
        if (len == 0) return;

        uint256 idx = listingSeed % len;
        uint256 bondId = ghostActiveListingBondIds[idx];
        address seller = ghostListingSeller[bondId];
        uint128 price = ghostListingPrice[bondId];

        // Pick a buyer that is not the seller
        address buyer = _pickActorExcluding(buyerSeed, seller);
        if (buyer == address(0)) return;

        // Pre-flight: bond outstanding, seller still owns, listing not expired, buyer can pay
        if (!ghostBondOutstanding[bondId]) return;
        if (ghostBondOwner[bondId] != seller) return;
        if (buyer.balance < price) return;
        (,, uint64 exp) = marketplace.sListings(bondId);
        if (block.timestamp > exp) return;

        vm.prank(buyer);
        marketplace.buy{value: price}(bondId, price, 0);

        _removeListingFromGhost(bondId, idx);
        ghostBondOwner[bondId] = buyer;
        ++ghostTotalListingsPurchased;
    }

    /// @notice Make a WETH offer on a random outstanding bond
    function handlerMakeOffer(uint256 buyerSeed, uint256 bondSeed, uint128 amount, uint64 expOffset) external {
        ++callsMakeOffer;
        if (ghostMintedBondIds.length == 0) return;

        address buyer = actors[buyerSeed % actors.length];
        uint256 bondId = _findOutstandingBond(bondSeed);
        if (bondId == 0) return;

        uint256 wethBal = weth.balanceOf(buyer);
        if (wethBal == 0) return;
        amount = uint128(bound(amount, 1, wethBal));
        uint64 expiration = uint64(block.timestamp + bound(expOffset, 1, 365 days));

        if (weth.allowance(buyer, address(marketplace)) < amount) return;

        vm.prank(buyer);
        marketplace.makeOffer(bondId, amount, expiration, 0);

        // New offer or overwrite for same (bondId, buyer) pair
        bytes32 key = _offerKey(bondId, buyer);
        if (ghostHasActiveOffer[key]) {
            ++ghostTotalOffersInvalidated; // old offer replaced
        } else {
            _ghostOfferIdx[key] = _ghostActiveOfferKeys.length;
            _ghostActiveOfferKeys.push(GhostOfferKey({bondId: bondId, buyer: buyer}));
            ghostHasActiveOffer[key] = true;
        }
        ghostOfferAmount[key] = amount;
        ++ghostTotalOffersMade;
    }

    /// @notice Cancel a random active offer
    function handlerCancelOffer(uint256 offerSeed) external {
        ++callsCancelOffer;
        uint256 len = _ghostActiveOfferKeys.length;
        if (len == 0) return;

        uint256 idx = offerSeed % len;
        GhostOfferKey memory ok_ = _ghostActiveOfferKeys[idx];

        vm.prank(ok_.buyer);
        marketplace.cancelOffer(ok_.bondId, 0);

        _removeOfferFromGhost(ok_.bondId, ok_.buyer, idx);
        ++ghostTotalOffersCancelled;
    }

    /// @notice Accept a random active offer (called by current bond owner)
    function handlerAcceptOffer(uint256 offerSeed) external {
        ++callsAcceptOffer;
        uint256 len = _ghostActiveOfferKeys.length;
        if (len == 0) return;

        uint256 idx = offerSeed % len;
        GhostOfferKey memory ok_ = _ghostActiveOfferKeys[idx];
        bytes32 key = _offerKey(ok_.bondId, ok_.buyer);

        address seller = ghostBondOwner[ok_.bondId];
        if (seller == address(0)) return;
        if (!ghostBondOutstanding[ok_.bondId]) return;

        // Check offer not expired
        (, uint64 exp,,) = marketplace.sOffers(ok_.bondId, ok_.buyer);
        if (block.timestamp > exp) return;

        // Check buyer's WETH
        uint128 amount = ghostOfferAmount[key];
        if (weth.balanceOf(ok_.buyer) < amount) return;
        if (weth.allowance(ok_.buyer, address(marketplace)) < amount) return;

        // Check seller has marketplace approval
        if (!bondNft.isApprovedForAll(seller, address(marketplace))) return;

        vm.prank(seller);
        marketplace.acceptOffer(ok_.bondId, ok_.buyer, amount);

        _removeOfferFromGhost(ok_.bondId, ok_.buyer, idx);
        ghostBondOwner[ok_.bondId] = ok_.buyer;
        ++ghostTotalOffersAccepted;

        // Remove stale listing if seller changed
        if (ghostHasActiveListing[ok_.bondId] && ghostListingSeller[ok_.bondId] != ok_.buyer) {
            _removeListingFromGhost(ok_.bondId, _ghostListingIdx[ok_.bondId]);
            ++ghostTotalListingsInvalidated;
        }
    }

    /// @notice Advance block.timestamp to test expirations
    function handlerWarpTime(uint256 seconds_) external {
        ++callsWarpTime;
        uint256 advance = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + advance);
    }

    /// @notice Make a bond non-outstanding (invalidates all trades for it)
    function handlerSetNonOutstanding(uint256 bondSeed) external {
        ++callsSetNonOutstanding;
        if (ghostMintedBondIds.length == 0) return;

        uint256 bondId = ghostMintedBondIds[bondSeed % ghostMintedBondIds.length];
        if (!ghostBondOutstanding[bondId]) return;

        coffer.setMaturityValue(bondId, 0);
        ghostBondOutstanding[bondId] = false;

        // Remove listing (can't trade non-outstanding bond)
        if (ghostHasActiveListing[bondId]) {
            _removeListingFromGhost(bondId, _ghostListingIdx[bondId]);
            ++ghostTotalListingsInvalidated;
        }

        // Remove all offers for this bond (backward iteration for safe swap-and-pop)
        for (uint256 i = _ghostActiveOfferKeys.length; i > 0;) {
            --i;
            if (_ghostActiveOfferKeys[i].bondId == bondId) {
                GhostOfferKey memory ok_ = _ghostActiveOfferKeys[i];
                _removeOfferFromGhost(ok_.bondId, ok_.buyer, i);
                ++ghostTotalOffersInvalidated;
            }
        }
    }

    /// @notice Transfer an NFT outside the marketplace (creates stale listings)
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

        // Remove stale listing (seller no longer owns NFT)
        if (ghostHasActiveListing[bondId]) {
            _removeListingFromGhost(bondId, _ghostListingIdx[bondId]);
            ++ghostTotalListingsInvalidated;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                       View Accessors
    // ═══════════════════════════════════════════════════════════════

    function getActiveListingCount() external view returns (uint256) {
        return ghostActiveListingBondIds.length;
    }

    function getActiveListingBondIdAt(uint256 index) external view returns (uint256) {
        return ghostActiveListingBondIds[index];
    }

    function getActiveOfferCount() external view returns (uint256) {
        return _ghostActiveOfferKeys.length;
    }

    function getActiveOfferKeyAt(uint256 index) external view returns (uint256 bondId, address buyer) {
        GhostOfferKey memory ok_ = _ghostActiveOfferKeys[index];
        return (ok_.bondId, ok_.buyer);
    }

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

    function _offerKey(uint256 bondId, address buyer) internal pure returns (bytes32) {
        return keccak256(abi.encode(bondId, buyer));
    }

    /// @dev Swap-and-pop removal for listings
    function _removeListingFromGhost(uint256 bondId, uint256 idx) internal {
        uint256 lastIdx = ghostActiveListingBondIds.length - 1;
        if (idx != lastIdx) {
            uint256 lastBondId = ghostActiveListingBondIds[lastIdx];
            ghostActiveListingBondIds[idx] = lastBondId;
            _ghostListingIdx[lastBondId] = idx;
        }
        ghostActiveListingBondIds.pop();
        delete ghostHasActiveListing[bondId];
        delete _ghostListingIdx[bondId];
        delete ghostListingSeller[bondId];
        delete ghostListingPrice[bondId];
    }

    /// @dev Swap-and-pop removal for offers
    function _removeOfferFromGhost(uint256 bondId, address buyer, uint256 idx) internal {
        bytes32 key = _offerKey(bondId, buyer);
        uint256 lastIdx = _ghostActiveOfferKeys.length - 1;
        if (idx != lastIdx) {
            GhostOfferKey memory lastKey = _ghostActiveOfferKeys[lastIdx];
            _ghostActiveOfferKeys[idx] = lastKey;
            _ghostOfferIdx[_offerKey(lastKey.bondId, lastKey.buyer)] = idx;
        }
        _ghostActiveOfferKeys.pop();
        delete ghostHasActiveOffer[key];
        delete _ghostOfferIdx[key];
        delete ghostOfferAmount[key];
    }

    /// @dev Find an outstanding bond owned by `owner`, starting from seed position
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

    /// @dev Find any outstanding bond, starting from seed position
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

    /// @dev Pick an actor that is not `exclude`
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
}
