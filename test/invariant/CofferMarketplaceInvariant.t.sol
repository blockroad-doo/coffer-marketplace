// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {
    CofferMarketplaceHandler,
    HandlerWallet,
    MockBondNftForHandler,
    MockCofferForHandler,
    MockWETHForHandler
} from "./CofferMarketplaceHandler.sol";

/// @title CofferMarketplaceInvariantTest
/// @notice Invariant suite. Run with:  FOUNDRY_PROFILE=invariants forge test -vv
/// @dev Strict is the only mode: [invariant] fail_on_revert = true in foundry.toml. The handler
///      predicts every marketplace revert with an exact vm.expectRevert oracle and asserts
///      settlement postconditions on every fill, so an unexpected revert, an oracle mismatch or a
///      failed postcondition fails the run with a counterexample. Under fail_on_revert = false both
///      would be silently swallowed, which is why no permissive profile exists.
///      Each invariant_* function is its own fuzz campaign. afterInvariant() prints the handler
///      counters of a campaign's last run at -vv; forge's metrics table (show_metrics, on by
///      default) gives the campaign-wide calls, reverts and discards per handler selector, and
///      must show zero reverts.
contract CofferMarketplaceInvariantTest is Test {
    CofferMarketplace public marketplace;
    MockBondNftForHandler public bondNft;
    MockCofferForHandler public coffer;
    MockWETHForHandler public weth;
    CofferMarketplaceHandler public handler;

    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
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
        total += feeRecipient.balance;
        assertEq(total, handler.ghostInitialTotalEth(), "Total ETH must be conserved");
    }

    function invariant_wethConservation() public view {
        uint256 total;
        uint256 numActors = handler.getActorsLength();
        for (uint256 i; i < numActors; ++i) {
            total += weth.balanceOf(handler.getActorAt(i));
        }
        total += weth.balanceOf(address(marketplace));
        total += weth.balanceOf(feeRecipient);
        // The listing fallback deposits the price into WETH, which mints
        assertEq(
            total, handler.ghostInitialTotalWeth() + handler.ghostWethMintedByFallback(), "Total WETH must be conserved"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 1b, Fee ledger and admin mirror
    // ═══════════════════════════════════════════════════════════════

    /// @dev The contract keeps no fee ledger, the handler does: every settled fill adds its fee in its own asset,
    ///      every sweep removes the whole balance of its asset.
    function invariant_feeLedger() public view {
        assertEq(address(marketplace).balance, handler.ghostEthAccrued() - handler.ghostEthClaimed(), "ETH fee ledger");
        assertEq(
            weth.balanceOf(address(marketplace)),
            handler.ghostWethAccrued() - handler.ghostWethClaimed(),
            "WETH fee ledger"
        );
    }

    /// @dev Owner, pending owner and fee recipient mirror the handler's prediction and never go to zero.
    function invariant_adminMirror() public view {
        assertEq(marketplace.owner(), handler.ghostOwner(), "owner mirror");
        assertTrue(marketplace.owner() != address(0), "owner never zero");
        assertEq(marketplace.pendingOwner(), handler.ghostPendingOwner(), "pending owner mirror");
        assertEq(marketplace.sFeeRecipient(), handler.ghostFeeRecipient(), "fee recipient mirror");
        assertTrue(marketplace.sFeeRecipient() != address(0), "fee recipient never zero");
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category 2, Predicted ghost state vs chain
    // ═══════════════════════════════════════════════════════════════

    // The handler never reads nonces or ownership back from the chain. It predicts them: a fill
    // or a single cancel advances exactly one per-bond nonce by one, cancelAll advances exactly
    // the global nonce by one, a fill moves the NFT to the taker. These invariants compare the
    // prediction with the chain for every (actor, bond) key, so a bump of the wrong key, by the
    // wrong amount, or a missing bump fails here (and, for nonces, also as an oracle mismatch at
    // the handler's next fill attempt).

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
    //  Summary (last run of each campaign, printed at -vv)
    // ═══════════════════════════════════════════════════════════════

    function afterInvariant() public view {
        console2.log("--- Handler calls ---");
        console2.log("mintBond:                 ", handler.callsMintBond());
        console2.log("signListing:              ", handler.callsSignListing());
        console2.log("cancelListing:            ", handler.callsCancelListing());
        console2.log("cancelAllListings:        ", handler.callsCancelAllListings());
        console2.log("buySignedListing:         ", handler.callsBuySignedListing());
        console2.log("signOffer:                ", handler.callsSignOffer());
        console2.log("cancelOffer:              ", handler.callsCancelOffer());
        console2.log("cancelAllOffers:          ", handler.callsCancelAllOffers());
        console2.log("acceptSignedOffer:        ", handler.callsAcceptSignedOffer());
        console2.log("warpTime:                 ", handler.callsWarpTime());
        console2.log("setNonOutstanding:        ", handler.callsSetNonOutstanding());
        console2.log("transferNft:              ", handler.callsTransferNft());
        console2.log("cancelListings:           ", handler.callsCancelListings());
        console2.log("  entries:                ", handler.callsCancelListingsEntries());
        console2.log("cancelOffers:             ", handler.callsCancelOffers());
        console2.log("  entries:                ", handler.callsCancelOffersEntries());
        console2.log("claimFees:                ", handler.callsClaimFees());
        console2.log("claimWethFees:            ", handler.callsClaimWethFees());
        console2.log("setFeeRecipient:          ", handler.callsSetFeeRecipient());
        console2.log("transferOwnership:        ", handler.callsTransferOwnership());
        console2.log("acceptOwnership:          ", handler.callsAcceptOwnership());
        console2.log("renounceOwnership:        ", handler.callsRenounceOwnership());
        console2.log("impairBond:               ", handler.callsImpairBond());
        console2.log("setApproval:              ", handler.callsSetApproval());
        console2.log("admin throttled:          ", handler.skippedAdminThrottled());
        console2.log("setWalletMode:            ", handler.callsSetWalletMode());
        console2.log("fallback payouts:         ", handler.ghostFallbackPayouts());
        console2.log("wallet fills settled:     ", handler.ghostWalletFillsSettled());
        console2.log("--- Signed messages ---");
        console2.log("mintedBonds:              ", handler.getMintedBondCount());
        console2.log("listingsCreated:          ", handler.ghostTotalListingsCreated());
        console2.log("listingsPurchased:        ", handler.ghostTotalListingsPurchased());
        console2.log("listingsCancelled:        ", handler.ghostTotalListingsCancelled());
        console2.log("listingsRevoked:          ", handler.ghostTotalListingsRevoked());
        console2.log("cancelAll throttled:      ", handler.skippedCancelAllListingsThrottled());
        console2.log("offersMade:               ", handler.ghostTotalOffersMade());
        console2.log("offersAccepted:           ", handler.ghostTotalOffersAccepted());
        console2.log("offersCancelled:          ", handler.ghostTotalOffersCancelled());
        console2.log("offersRevoked:            ", handler.ghostTotalOffersRevoked());
        console2.log("cancelAll throttled:      ", handler.skippedCancelAllOffersThrottled());
        console2.log("--- Oracle: buy attempts rejected as predicted ---");
        console2.log("SameParty:                ", _buyRejected(CofferMarketplace.SameParty.selector));
        console2.log("ListingRevoked:           ", _buyRejected(CofferMarketplace.ListingRevoked.selector));
        console2.log("SellerNoLongerOwnsNft:    ", _buyRejected(CofferMarketplace.SellerNoLongerOwnsNft.selector));
        console2.log("MarketplaceNotApproved:   ", _buyRejected(CofferMarketplace.MarketplaceNotApproved.selector));
        console2.log("InvalidSignature:         ", _buyRejected(CofferMarketplace.InvalidSignature.selector));
        console2.log("HookRejected:             ", _buyRejected(HandlerWallet.HookRejected.selector));
        console2.log("InsufficientPayment:      ", _buyRejected(CofferMarketplace.InsufficientPayment.selector));
        console2.log("ExpirationNotInFuture:    ", _buyRejected(CofferMarketplace.ExpirationNotInFuture.selector));
        console2.log("BondNotOutstanding:       ", _buyRejected(CofferMarketplace.BondNotOutstanding.selector));
        console2.log("MaturityValueMismatch:    ", _buyRejected(CofferMarketplace.MaturityValueMismatch.selector));
        console2.log("replays after a fill:     ", handler.ghostBuyReplaysRejected());
        console2.log("skipped, no listing signed: ", handler.skippedBuyNoListing());
        console2.log("skipped, buyer ETH short: ", handler.skippedBuyInsufficientEth());
        console2.log("--- Oracle: accept attempts rejected as predicted ---");
        console2.log("SameParty:                ", _acceptRejected(CofferMarketplace.SameParty.selector));
        console2.log("OfferRevoked:             ", _acceptRejected(CofferMarketplace.OfferRevoked.selector));
        console2.log("NotOwner:                 ", _acceptRejected(CofferMarketplace.NotOwner.selector));
        console2.log("MarketplaceNotApproved:   ", _acceptRejected(CofferMarketplace.MarketplaceNotApproved.selector));
        console2.log("InvalidSignature:         ", _acceptRejected(CofferMarketplace.InvalidSignature.selector));
        console2.log("ExpirationNotInFuture:    ", _acceptRejected(CofferMarketplace.ExpirationNotInFuture.selector));
        console2.log("BondNotOutstanding:       ", _acceptRejected(CofferMarketplace.BondNotOutstanding.selector));
        console2.log("MaturityValueMismatch:    ", _acceptRejected(CofferMarketplace.MaturityValueMismatch.selector));
        console2.log("InsufficientPayment:      ", _acceptRejected(CofferMarketplace.InsufficientPayment.selector));
        console2.log("replays after a fill:     ", handler.ghostAcceptReplaysRejected());
        console2.log("skipped, no offer signed:  ", handler.skippedAcceptNoOffer());
    }

    function _buyRejected(bytes4 selector) internal view returns (uint256) {
        return handler.ghostBuyRejectedBySelector(selector);
    }

    function _acceptRejected(bytes4 selector) internal view returns (uint256) {
        return handler.ghostAcceptRejectedBySelector(selector);
    }
}
