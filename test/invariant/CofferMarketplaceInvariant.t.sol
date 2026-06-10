// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {
    CofferMarketplaceHandler,
    MockBondNftForHandler,
    MockCofferForHandler,
    MockWETHForHandler
} from "./CofferMarketplaceHandler.sol";

/// @title CofferMarketplaceInvariantTest
/// @notice Permissive invariant tests (fail_on_revert = false).
///         Handlers silently return on invalid inputs; reverts are absorbed.
contract CofferMarketplaceInvariantTest is Test {
    CofferMarketplace public marketplace;
    MockBondNftForHandler public bondNft;
    MockCofferForHandler public coffer;
    MockWETHForHandler public weth;
    CofferMarketplaceHandler public handler;

    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    function setUp() public virtual {
        vm.warp(100_000);

        coffer = new MockCofferForHandler();
        bondNft = new MockBondNftForHandler();
        weth = new MockWETHForHandler();
        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        handler = new CofferMarketplaceHandler(marketplace, bondNft, coffer, weth);
        targetContract(address(handler));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 1, Conservation (no value created or destroyed)
    // ═══════════════════════════════════════════════════════════════

    function invariant_ethConservation() public view {
        uint256 total;
        uint256 numActors = handler.getActorsLength();
        for (uint256 i; i < numActors; ++i) {
            total += handler.getActorAt(i).balance;
        }
        total += address(marketplace).balance;
        total += address(weth).balance;
        assertEq(total, handler.ghostInitialTotalEth(), "Total ETH must be conserved");
    }

    function invariant_wethConservation() public view {
        uint256 total;
        uint256 numActors = handler.getActorsLength();
        for (uint256 i; i < numActors; ++i) {
            total += weth.balanceOf(handler.getActorAt(i));
        }
        total += weth.balanceOf(address(marketplace));
        assertEq(total, handler.ghostInitialTotalWeth(), "Total WETH must be conserved");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 2, Ghost-to-Chain Consistency (nonce mirroring)
    // ═══════════════════════════════════════════════════════════════

    function invariant_listingNoncesMatchOnChain() public view {
        uint256 numActors = handler.getActorsLength();
        uint256 numBonds = handler.getMintedBondCount();
        for (uint256 i; i < numActors; ++i) {
            address actor = handler.getActorAt(i);
            assertEq(
                handler.ghostListingGlobalNonce(actor),
                marketplace.sGlobalListingNonce(actor),
                "Global listing nonce mismatch"
            );
            for (uint256 j; j < numBonds; ++j) {
                uint256 bondId = handler.getMintedBondIdAt(j);
                assertEq(
                    handler.ghostListingNonce(actor, bondId),
                    marketplace.sListingNonce(actor, bondId),
                    "Per-bond listing nonce mismatch"
                );
            }
        }
    }

    function invariant_offerNoncesMatchOnChain() public view {
        uint256 numActors = handler.getActorsLength();
        uint256 numBonds = handler.getMintedBondCount();
        for (uint256 i; i < numActors; ++i) {
            address actor = handler.getActorAt(i);
            assertEq(
                handler.ghostOfferGlobalNonce(actor),
                marketplace.sGlobalOfferNonce(actor),
                "Global offer nonce mismatch"
            );
            for (uint256 j; j < numBonds; ++j) {
                uint256 bondId = handler.getMintedBondIdAt(j);
                assertEq(
                    handler.ghostOfferNonce(actor, bondId),
                    marketplace.sOfferNonce(actor, bondId),
                    "Per-bond offer nonce mismatch"
                );
            }
        }
    }

    function invariant_nftOwnershipMatchesGhost() public view {
        uint256 count = handler.getMintedBondCount();
        for (uint256 i; i < count; ++i) {
            uint256 bondId = handler.getMintedBondIdAt(i);
            assertEq(bondNft.ownerOf(bondId), handler.ghostBondOwner(bondId), "NFT ownership mismatch");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 3, Structural Integrity
    // ═══════════════════════════════════════════════════════════════

    function invariant_bondOwnershipIsTracked() public view {
        uint256 count = handler.getMintedBondCount();
        for (uint256 i; i < count; ++i) {
            uint256 bondId = handler.getMintedBondIdAt(i);
            address owner = handler.ghostBondOwner(bondId);
            assertTrue(owner != address(0), "Every minted bond must have a ghost owner");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 4, Lifecycle Accounting
    // ═══════════════════════════════════════════════════════════════

    function invariant_listingLifecycle_nonNegative() public view {
        uint256 created = handler.ghostTotalListingsCreated();
        uint256 purchased = handler.ghostTotalListingsPurchased();
        uint256 cancelled = handler.ghostTotalListingsCancelled();
        uint256 revoked = handler.ghostTotalListingsRevoked();
        assertLe(purchased + cancelled + revoked, created, "Listings resolved exceed created");
    }

    function invariant_offerLifecycle_nonNegative() public view {
        uint256 made = handler.ghostTotalOffersMade();
        uint256 accepted = handler.ghostTotalOffersAccepted();
        uint256 cancelled = handler.ghostTotalOffersCancelled();
        uint256 revoked = handler.ghostTotalOffersRevoked();
        assertLe(accepted + cancelled + revoked, made, "Offers resolved exceed made");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 5, Bond Integrity
    // ═══════════════════════════════════════════════════════════════

    /// @notice The handler's per-bond outstanding flag must always mirror the on-chain coffer state.
    /// @dev "Listed ⇒ outstanding" is NOT a protocol invariant: a bond can become non-outstanding
    ///      (maturity / redemption, modelled by handlerSetNonOutstanding) while a listing signature
    ///      still exists, the marketplace simply makes that listing unfillable (buySignedListing
    ///      reverts BondNotOutstanding) rather than cancelling it. So we assert the ghost-vs-chain
    ///      mirror instead, analogous to the nonce and NFT-ownership mirror invariants.
    function invariant_bondOutstandingMatchesChain() public view {
        uint256 numBonds = handler.getMintedBondCount();
        for (uint256 j; j < numBonds; ++j) {
            uint256 bondId = handler.getMintedBondIdAt(j);
            bool chainOutstanding = coffer.maturityValues(bondId) != 0;
            assertEq(
                handler.ghostBondOutstanding(bondId), chainOutstanding, "Ghost outstanding flag desynced from chain"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 6, Debug
    // ═══════════════════════════════════════════════════════════════

    function invariant_callSummary() public view {
        console2.log("--- Call Summary ---");
        console2.log("mintBond:              ", handler.callsMintBond());
        console2.log("signListing:           ", handler.callsSignListing());
        console2.log("cancelListing:         ", handler.callsCancelListing());
        console2.log("cancelAllListings:     ", handler.callsCancelAllListings());
        console2.log("buySignedListing:      ", handler.callsBuySignedListing());
        console2.log("signOffer:             ", handler.callsSignOffer());
        console2.log("cancelOffer:           ", handler.callsCancelOffer());
        console2.log("cancelAllOffers:       ", handler.callsCancelAllOffers());
        console2.log("acceptSignedOffer:     ", handler.callsAcceptSignedOffer());
        console2.log("warpTime:              ", handler.callsWarpTime());
        console2.log("setNonOutstanding:     ", handler.callsSetNonOutstanding());
        console2.log("transferNft:           ", handler.callsTransferNft());
        console2.log("--- Ghost Counters ---");
        console2.log("mintedBonds:           ", handler.getMintedBondCount());
        console2.log("listingsCreated:       ", handler.ghostTotalListingsCreated());
        console2.log("listingsPurchased:     ", handler.ghostTotalListingsPurchased());
        console2.log("listingsCancelled:     ", handler.ghostTotalListingsCancelled());
        console2.log("listingsRevoked:       ", handler.ghostTotalListingsRevoked());
        console2.log("offersMade:            ", handler.ghostTotalOffersMade());
        console2.log("offersAccepted:        ", handler.ghostTotalOffersAccepted());
        console2.log("offersCancelled:       ", handler.ghostTotalOffersCancelled());
        console2.log("offersRevoked:         ", handler.ghostTotalOffersRevoked());
    }
}
