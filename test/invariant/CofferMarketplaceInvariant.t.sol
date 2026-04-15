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

    function setUp() public virtual {
        vm.warp(100_000); // Stable starting timestamp

        coffer = new MockCofferForHandler();
        bondNft = new MockBondNftForHandler();
        weth = new MockWETHForHandler();
        marketplace = new CofferMarketplace(address(weth), address(bondNft));

        handler = new CofferMarketplaceHandler(marketplace, bondNft, coffer, weth);
        targetContract(address(handler));
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 1 — Zero Balance (marketplace is a pure pass-through)
    // ═══════════════════════════════════════════════════════════════

    function invariant_marketplaceNeverHoldsEth() public view {
        assertEq(address(marketplace).balance, 0, "Marketplace must never hold ETH");
    }

    function invariant_marketplaceNeverHoldsWeth() public view {
        assertEq(weth.balanceOf(address(marketplace)), 0, "Marketplace must never hold WETH");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 2 — Conservation (no value created or destroyed)
    // ═══════════════════════════════════════════════════════════════

    function invariant_ethConservation() public view {
        uint256 total;
        uint256 numActors = handler.getActorsLength();
        for (uint256 i; i < numActors; ++i) {
            total += handler.getActorAt(i).balance;
        }
        total += address(marketplace).balance;
        // WETH contract holds ETH backing wrapped tokens (including from WETH fallback in _buy)
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
    //  Category 3 — Ghost-to-Chain Consistency
    // ═══════════════════════════════════════════════════════════════

    function invariant_ghostListingsMatchOnChain() public view {
        uint256 count = handler.getActiveListingCount();
        for (uint256 i; i < count; ++i) {
            uint256 bondId = handler.getActiveListingBondIdAt(i);
            (address seller, uint128 price,) = marketplace.sListings(bondId);
            assertEq(seller, handler.ghostListingSeller(bondId), "Listing seller mismatch");
            assertEq(price, handler.ghostListingPrice(bondId), "Listing price mismatch");
        }
    }

    function invariant_ghostOffersMatchOnChain() public view {
        uint256 count = handler.getActiveOfferCount();
        for (uint256 i; i < count; ++i) {
            (uint256 bondId, address buyer) = handler.getActiveOfferKeyAt(i);
            (, uint128 amount,) = marketplace.sOffers(bondId, buyer);
            bytes32 key = keccak256(abi.encode(bondId, buyer));
            assertEq(amount, handler.ghostOfferAmount(key), "Offer amount mismatch");
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
    //  Category 4 — Structural Integrity
    // ═══════════════════════════════════════════════════════════════

    function invariant_activeListingsHavePositivePrice() public view {
        uint256 count = handler.getActiveListingCount();
        for (uint256 i; i < count; ++i) {
            uint256 bondId = handler.getActiveListingBondIdAt(i);
            (, uint128 price,) = marketplace.sListings(bondId);
            assertGt(price, 0, "Active listing must have positive price");
        }
    }

    function invariant_activeOffersHavePositiveAmount() public view {
        uint256 count = handler.getActiveOfferCount();
        for (uint256 i; i < count; ++i) {
            (uint256 bondId, address buyer) = handler.getActiveOfferKeyAt(i);
            (, uint128 amount,) = marketplace.sOffers(bondId, buyer);
            assertGt(amount, 0, "Active offer must have positive amount");
        }
    }

    function invariant_activeListingsHaveNonZeroSeller() public view {
        uint256 count = handler.getActiveListingCount();
        for (uint256 i; i < count; ++i) {
            uint256 bondId = handler.getActiveListingBondIdAt(i);
            (address seller,,) = marketplace.sListings(bondId);
            assertTrue(seller != address(0), "Active listing must have non-zero seller");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 5 — Lifecycle Accounting
    // ═══════════════════════════════════════════════════════════════

    function invariant_listingLifecycle() public view {
        assertEq(
            handler.ghostTotalListingsCreated(),
            handler.ghostTotalListingsPurchased() + handler.ghostTotalListingsCancelled()
                + handler.ghostTotalListingsInvalidated() + handler.getActiveListingCount(),
            "Listing lifecycle: created = purchased + cancelled + invalidated + active"
        );
    }

    function invariant_offerLifecycle() public view {
        assertEq(
            handler.ghostTotalOffersMade(),
            handler.ghostTotalOffersAccepted() + handler.ghostTotalOffersCancelled()
                + handler.ghostTotalOffersInvalidated() + handler.getActiveOfferCount(),
            "Offer lifecycle: made = accepted + cancelled + invalidated + active"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 6 — Bond Integrity
    // ═══════════════════════════════════════════════════════════════

    function invariant_everyListedBondIsOutstanding() public view {
        uint256 count = handler.getActiveListingCount();
        for (uint256 i; i < count; ++i) {
            uint256 bondId = handler.getActiveListingBondIdAt(i);
            assertTrue(handler.ghostBondOutstanding(bondId), "Ghost-tracked listed bond must be outstanding");
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 7 — Debug
    // ═══════════════════════════════════════════════════════════════

    // solhint-disable-next-line no-empty-blocks
    function invariant_callSummary() public view {
        console2.log("--- Call Summary ---");
        console2.log("mintBond:          ", handler.callsMintBond());
        console2.log("list:              ", handler.callsList());
        console2.log("cancelListing:     ", handler.callsCancelListing());
        console2.log("buy:               ", handler.callsBuy());
        console2.log("makeOffer:         ", handler.callsMakeOffer());
        console2.log("cancelOffer:       ", handler.callsCancelOffer());
        console2.log("acceptOffer:       ", handler.callsAcceptOffer());
        console2.log("warpTime:          ", handler.callsWarpTime());
        console2.log("setNonOutstanding: ", handler.callsSetNonOutstanding());
        console2.log("transferNft:       ", handler.callsTransferNft());
        console2.log("--- Ghost State ---");
        console2.log("activeListings:    ", handler.getActiveListingCount());
        console2.log("activeOffers:      ", handler.getActiveOfferCount());
        console2.log("mintedBonds:       ", handler.getMintedBondCount());
        console2.log("listingsCreated:   ", handler.ghostTotalListingsCreated());
        console2.log("listingsPurchased: ", handler.ghostTotalListingsPurchased());
        console2.log("offersMade:        ", handler.ghostTotalOffersMade());
        console2.log("offersAccepted:    ", handler.ghostTotalOffersAccepted());
    }
}
