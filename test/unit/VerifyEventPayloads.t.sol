// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// Each cancel and admin event payload must equal the storage transition it reports: the post-bump nonce on
// a single cancel, the running value per entry on a batch cancel with a repeated id, the post-bump global
// nonce on a cancelAll, the recipient of record after setFeeRecipient, and the recipient's delta on both
// sweeps. Every topic and the data bytes are checked against the pinned emitter, so the expected arrays are
// built exactly. Nonces are advanced once before each single or global cancel so a zero default cannot pass.
// The two sweeps read the whole balance (README Fee Flow), so a dealt or minted balance is a faithful fixture.
contract VerifyEventPayloadsTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public bondA;
    uint256 public bondB;

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();
        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);
        bondA = bondNft.mintTo(seller, address(coffer));
        bondB = bondNft.mintTo(seller, address(coffer));
    }

    // ───── Listing cancels ─────

    function test_cancelListing_emitsPostBumpNonce() public {
        vm.prank(seller);
        marketplace.cancelListing(bondA); // 0 -> 1

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.ListingCancelled(seller, bondA, 2);
        vm.prank(seller);
        marketplace.cancelListing(bondA);

        assertEq(marketplace.sListingNonce(seller, bondA), 2, "payload equals storage after the call");
    }

    function test_cancelListings_emitsRunningNonces() public {
        vm.prank(seller);
        marketplace.cancelListing(bondA); // bondA starts at 1, bondB at 0

        uint256[] memory ids = new uint256[](3);
        ids[0] = bondA;
        ids[1] = bondA;
        ids[2] = bondB;
        uint256[] memory running = new uint256[](3);
        running[0] = 2;
        running[1] = 3;
        running[2] = 1;

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.ListingsCancelled(seller, ids, running);
        vm.prank(seller);
        marketplace.cancelListings(ids);

        assertEq(marketplace.sListingNonce(seller, bondA), 3);
        assertEq(marketplace.sListingNonce(seller, bondB), 1);
    }

    function test_cancelAllListings_emitsPostBumpGlobalNonce() public {
        vm.prank(seller);
        marketplace.cancelAllListings(); // 0 -> 1

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.AllListingsCancelled(seller, 2);
        vm.prank(seller);
        marketplace.cancelAllListings();

        assertEq(marketplace.sGlobalListingNonce(seller), 2);
    }

    // ───── Offer cancels ─────

    function test_cancelOffer_emitsPostBumpNonce() public {
        vm.prank(buyer);
        marketplace.cancelOffer(bondA); // 0 -> 1

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.OfferCancelled(buyer, bondA, 2);
        vm.prank(buyer);
        marketplace.cancelOffer(bondA);

        assertEq(marketplace.sOfferNonce(buyer, bondA), 2, "payload equals storage after the call");
    }

    function test_cancelOffers_emitsRunningNonces() public {
        vm.prank(buyer);
        marketplace.cancelOffer(bondA); // bondA starts at 1, bondB at 0

        uint256[] memory ids = new uint256[](3);
        ids[0] = bondA;
        ids[1] = bondA;
        ids[2] = bondB;
        uint256[] memory running = new uint256[](3);
        running[0] = 2;
        running[1] = 3;
        running[2] = 1;

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.OffersCancelled(buyer, ids, running);
        vm.prank(buyer);
        marketplace.cancelOffers(ids);

        assertEq(marketplace.sOfferNonce(buyer, bondA), 3);
        assertEq(marketplace.sOfferNonce(buyer, bondB), 1);
    }

    function test_cancelAllOffers_emitsPostBumpGlobalNonce() public {
        vm.prank(buyer);
        marketplace.cancelAllOffers(); // 0 -> 1

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.AllOffersCancelled(buyer, 2);
        vm.prank(buyer);
        marketplace.cancelAllOffers();

        assertEq(marketplace.sGlobalOfferNonce(buyer), 2);
    }

    // ───── Admin ─────

    function test_setFeeRecipient_emitsRecipient() public {
        address next = makeAddr("nextRecipient");

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.FeeRecipientSet(next);
        vm.prank(mpOwner);
        marketplace.setFeeRecipient(next);

        assertEq(marketplace.sFeeRecipient(), next);
    }

    function test_constructor_emitsFeeRecipientSet() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectEmit(true, true, true, true, predicted);
        emit CofferMarketplace.FeeRecipientSet(feeRecipient);
        CofferMarketplace fresh = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        assertEq(address(fresh), predicted);
        assertEq(fresh.sFeeRecipient(), feeRecipient);
    }

    function test_claimFees_emitsAmountEqualToRecipientDelta() public {
        uint256 accrued = 0.36 ether;
        vm.deal(address(marketplace), accrued);
        uint256 before = feeRecipient.balance;

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.FeesClaimed(feeRecipient, accrued);
        vm.prank(mpOwner);
        marketplace.claimFees();

        assertEq(feeRecipient.balance - before, accrued, "amount equals the recipient's delta");
        assertEq(address(marketplace).balance, 0);
    }

    function test_claimWethFees_emitsAmountEqualToRecipientDelta() public {
        uint256 accrued = 0.36 ether;
        weth.mint(address(marketplace), accrued);
        uint256 before = weth.balanceOf(feeRecipient);

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.WethFeesClaimed(feeRecipient, accrued);
        vm.prank(mpOwner);
        marketplace.claimWethFees();

        assertEq(weth.balanceOf(feeRecipient) - before, accrued, "amount equals the recipient's delta");
        assertEq(weth.balanceOf(address(marketplace)), 0);
    }
}
