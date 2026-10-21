// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// Each cancel and admin event payload must equal the storage transition it reports: the new nonce on a
// single cancel, the running value per entry on a batch cancel with a repeated id, the new global nonce on
// a cancelAll, the recipient of record after setFeeRecipient, and the recipient's delta on both sweeps. A
// cancel moves its nonce by one plus an unpredictable amount, so the cancel events are read back from the
// recorded logs and checked against storage and against the value before the call, topics included. The
// admin events are checked against the pinned emitter. Nonces are moved once before each single or global
// cancel so a zero default cannot pass. The two sweeps read the whole balance (README Fee Flow), so a dealt
// or minted balance is a faithful fixture.
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

    // ───── Cancel events, read back from the recorded logs ─────

    function _singleLog() internal view returns (Vm.Log memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one event");
        return logs[0];
    }

    function _topic(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    // ───── Listing cancels ─────

    function test_cancelListing_emitsPostBumpNonce() public {
        vm.prank(seller);
        marketplace.cancelListing(bondA); // off zero
        uint256 before = marketplace.sListingNonce(seller, bondA);

        vm.recordLogs();
        vm.prank(seller);
        marketplace.cancelListing(bondA);

        Vm.Log memory log = _singleLog();
        assertEq(log.topics[0], CofferMarketplace.ListingCancelled.selector);
        assertEq(log.topics[1], _topic(seller));
        assertEq(log.topics[2], bytes32(bondA));
        uint256 emitted = abi.decode(log.data, (uint256));
        assertEq(emitted, marketplace.sListingNonce(seller, bondA), "payload equals storage after the call");
        assertGt(emitted, before, "the cancel moved the nonce forward");
    }

    function test_cancelListings_emitsRunningNonces() public {
        vm.prank(seller);
        marketplace.cancelListing(bondA); // bondA off zero, bondB at 0
        uint256 beforeA = marketplace.sListingNonce(seller, bondA);

        uint256[] memory ids = new uint256[](3);
        ids[0] = bondA;
        ids[1] = bondA;
        ids[2] = bondB;

        vm.recordLogs();
        vm.prank(seller);
        marketplace.cancelListings(ids);

        Vm.Log memory log = _singleLog();
        assertEq(log.topics[0], CofferMarketplace.ListingsCancelled.selector);
        assertEq(log.topics[1], _topic(seller));
        (uint256[] memory emittedIds, uint256[] memory running) = abi.decode(log.data, (uint256[], uint256[]));
        assertEq(emittedIds, ids);
        assertEq(running.length, 3);
        assertGt(running[0], beforeA, "the first entry moved bond A forward");
        assertGt(running[1], running[0], "the repeated id moved bond A forward again");
        assertEq(running[1], marketplace.sListingNonce(seller, bondA), "the last entry per bond equals storage");
        assertGt(running[2], 0, "bond B moved off zero");
        assertEq(running[2], marketplace.sListingNonce(seller, bondB));
    }

    function test_cancelAllListings_emitsPostBumpGlobalNonce() public {
        vm.prank(seller);
        marketplace.cancelAllListings(); // off zero
        uint256 before = marketplace.sGlobalListingNonce(seller);

        vm.recordLogs();
        vm.prank(seller);
        marketplace.cancelAllListings();

        Vm.Log memory log = _singleLog();
        assertEq(log.topics[0], CofferMarketplace.AllListingsCancelled.selector);
        assertEq(log.topics[1], _topic(seller));
        uint256 emitted = abi.decode(log.data, (uint256));
        assertEq(emitted, marketplace.sGlobalListingNonce(seller), "payload equals storage after the call");
        assertGt(emitted, before, "the cancel moved the global nonce forward");
    }

    // ───── Offer cancels ─────

    function test_cancelOffer_emitsPostBumpNonce() public {
        vm.prank(buyer);
        marketplace.cancelOffer(bondA); // off zero
        uint256 before = marketplace.sOfferNonce(buyer, bondA);

        vm.recordLogs();
        vm.prank(buyer);
        marketplace.cancelOffer(bondA);

        Vm.Log memory log = _singleLog();
        assertEq(log.topics[0], CofferMarketplace.OfferCancelled.selector);
        assertEq(log.topics[1], _topic(buyer));
        assertEq(log.topics[2], bytes32(bondA));
        uint256 emitted = abi.decode(log.data, (uint256));
        assertEq(emitted, marketplace.sOfferNonce(buyer, bondA), "payload equals storage after the call");
        assertGt(emitted, before, "the cancel moved the nonce forward");
    }

    function test_cancelOffers_emitsRunningNonces() public {
        vm.prank(buyer);
        marketplace.cancelOffer(bondA); // bondA off zero, bondB at 0
        uint256 beforeA = marketplace.sOfferNonce(buyer, bondA);

        uint256[] memory ids = new uint256[](3);
        ids[0] = bondA;
        ids[1] = bondA;
        ids[2] = bondB;

        vm.recordLogs();
        vm.prank(buyer);
        marketplace.cancelOffers(ids);

        Vm.Log memory log = _singleLog();
        assertEq(log.topics[0], CofferMarketplace.OffersCancelled.selector);
        assertEq(log.topics[1], _topic(buyer));
        (uint256[] memory emittedIds, uint256[] memory running) = abi.decode(log.data, (uint256[], uint256[]));
        assertEq(emittedIds, ids);
        assertEq(running.length, 3);
        assertGt(running[0], beforeA, "the first entry moved bond A forward");
        assertGt(running[1], running[0], "the repeated id moved bond A forward again");
        assertEq(running[1], marketplace.sOfferNonce(buyer, bondA), "the last entry per bond equals storage");
        assertGt(running[2], 0, "bond B moved off zero");
        assertEq(running[2], marketplace.sOfferNonce(buyer, bondB));
    }

    function test_cancelAllOffers_emitsPostBumpGlobalNonce() public {
        vm.prank(buyer);
        marketplace.cancelAllOffers(); // off zero
        uint256 before = marketplace.sGlobalOfferNonce(buyer);

        vm.recordLogs();
        vm.prank(buyer);
        marketplace.cancelAllOffers();

        Vm.Log memory log = _singleLog();
        assertEq(log.topics[0], CofferMarketplace.AllOffersCancelled.selector);
        assertEq(log.topics[1], _topic(buyer));
        uint256 emitted = abi.decode(log.data, (uint256));
        assertEq(emitted, marketplace.sGlobalOfferNonce(buyer), "payload equals storage after the call");
        assertGt(emitted, before, "the cancel moved the global nonce forward");
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
