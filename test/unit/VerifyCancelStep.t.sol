// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// A cancel raises its nonce by one plus an amount that was unpredictable when any existing signature
// was produced. These tests pin that a message signed at the next per-bond or global nonce is revoked
// by the cancel instead of armed, on both sides, and that every cancel moves its nonce forward by at
// least one and at most 2^128.
contract VerifyCancelStepTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    uint256 constant SELLER_PK = 0xA11CE;
    uint256 constant BUYER_PK = 0xB0B;
    uint256 constant MAX_STEP = 2 ** 128;

    address public seller;
    address public buyer;
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public bondA;

    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(address seller,uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant OFFER_TYPEHASH = keccak256(
        "Offer(address buyer,uint256 bondId,uint128 wethAmount,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("CofferMarketplace")),
                keccak256(bytes("5")),
                block.chainid,
                address(marketplace)
            )
        );
    }

    function _signListing(uint256 pk, uint256 bId, uint128 pr, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(LISTING_TYPEHASH, vm.addr(pk), bId, pr, mat, exp, nonce, gNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(uint256 pk, uint256 bId, uint128 wAmt, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, vm.addr(pk), bId, wAmt, mat, exp, nonce, gNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();
        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        seller = vm.addr(SELLER_PK);
        buyer = vm.addr(BUYER_PK);

        bondA = bondNft.mintTo(seller, address(coffer));

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.deal(buyer, 100 ether);
        weth.mint(buyer, 100 ether);
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);
    }

    // ───── A message signed at the next global nonce is revoked by cancelAll ─────

    function test_cancelAllListings_revokesListingSignedAtNextGlobalNonce() public {
        // A listing at a fraction of the bond's value, signed for the NEXT global nonce. It cannot be
        // filled before the cancel-all, and it cannot be filled after it either.
        uint128 price = 0.1 ether;
        uint64 exp = uint64(block.timestamp + 30 days);
        uint256 nextGlobal = marketplace.sGlobalListingNonce(seller) + 1;
        bytes memory sig = _signListing(SELLER_PK, bondA, price, 1 ether, exp, 0, nextGlobal);
        uint256 fee = (1 ether - uint256(price)) * 900 / 10_000;

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: price + fee}(bondA, seller, price, 1 ether, exp, 0, nextGlobal, sig);

        vm.prank(seller);
        marketplace.cancelAllListings();
        assertGt(marketplace.sGlobalListingNonce(seller), nextGlobal, "the cancel moved past the signed value");

        uint256 sellerBefore = seller.balance;
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: price + fee}(bondA, seller, price, 1 ether, exp, 0, nextGlobal, sig);

        assertEq(bondNft.ownerOf(bondA), seller, "bond stays with the seller");
        assertEq(seller.balance, sellerBefore, "seller receives nothing");
    }

    function test_cancelAllOffers_revokesOfferSignedAtNextGlobalNonce() public {
        // An offer far above the bond's value, signed for the NEXT global offer nonce.
        uint128 amount = 3 ether;
        uint64 exp = uint64(block.timestamp + 30 days);
        uint256 nextGlobal = marketplace.sGlobalOfferNonce(buyer) + 1;
        bytes memory sig = _signOffer(BUYER_PK, bondA, amount, 1 ether, exp, 0, nextGlobal);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondA, buyer, amount, 1 ether, exp, 0, nextGlobal, sig);

        vm.prank(buyer);
        marketplace.cancelAllOffers();
        assertGt(marketplace.sGlobalOfferNonce(buyer), nextGlobal, "the cancel moved past the signed value");

        uint256 buyerWethBefore = weth.balanceOf(buyer);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondA, buyer, amount, 1 ether, exp, 0, nextGlobal, sig);

        assertEq(bondNft.ownerOf(bondA), seller, "bond stays with the seller");
        assertEq(weth.balanceOf(buyer), buyerWethBefore, "buyer pays nothing");
    }

    // ───── A message signed at the next per-bond nonce is revoked by a single cancel ─────

    function test_cancelListing_revokesListingSignedAtNextNonce() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 next = marketplace.sListingNonce(seller, bondA) + 1;
        bytes memory sig = _signListing(SELLER_PK, bondA, 1 ether, 1 ether, exp, next, 0);

        vm.prank(seller);
        marketplace.cancelListing(bondA);
        assertGt(marketplace.sListingNonce(seller, bondA), next, "the cancel moved past the pre-signed nonce");

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: 1 ether}(bondA, seller, 1 ether, 1 ether, exp, next, 0, sig);
        assertEq(bondNft.ownerOf(bondA), seller, "bond stays with the seller");
    }

    function test_cancelOffer_revokesOfferSignedAtNextNonce() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 next = marketplace.sOfferNonce(buyer, bondA) + 1;
        bytes memory sig = _signOffer(BUYER_PK, bondA, 1 ether, 1 ether, exp, next, 0);

        vm.prank(buyer);
        marketplace.cancelOffer(bondA);
        assertGt(marketplace.sOfferNonce(buyer, bondA), next, "the cancel moved past the pre-signed nonce");

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondA, buyer, 1 ether, 1 ether, exp, next, 0, sig);
        assertEq(bondNft.ownerOf(bondA), seller, "bond stays with the seller");
    }

    // ───── Every cancel moves its nonce forward by at least one and at most 2^128 ─────

    function testFuzz_everyCancelRaisesTheNonceByAtLeastOne(uint8 kind, bytes32 prevrandao) public {
        kind = uint8(bound(kind, 0, 5));
        vm.prevrandao(prevrandao);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bondA;

        uint256 before;
        uint256 moved;
        if (kind == 0) {
            before = marketplace.sListingNonce(seller, bondA);
            vm.prank(seller);
            marketplace.cancelListing(bondA);
            moved = marketplace.sListingNonce(seller, bondA);
        } else if (kind == 1) {
            before = marketplace.sListingNonce(seller, bondA);
            vm.prank(seller);
            marketplace.cancelListings(ids);
            moved = marketplace.sListingNonce(seller, bondA);
        } else if (kind == 2) {
            before = marketplace.sGlobalListingNonce(seller);
            vm.prank(seller);
            marketplace.cancelAllListings();
            moved = marketplace.sGlobalListingNonce(seller);
        } else if (kind == 3) {
            before = marketplace.sOfferNonce(buyer, bondA);
            vm.prank(buyer);
            marketplace.cancelOffer(bondA);
            moved = marketplace.sOfferNonce(buyer, bondA);
        } else if (kind == 4) {
            before = marketplace.sOfferNonce(buyer, bondA);
            vm.prank(buyer);
            marketplace.cancelOffers(ids);
            moved = marketplace.sOfferNonce(buyer, bondA);
        } else {
            before = marketplace.sGlobalOfferNonce(buyer);
            vm.prank(buyer);
            marketplace.cancelAllOffers();
            moved = marketplace.sGlobalOfferNonce(buyer);
        }
        assertGe(moved, before + 1, "the cancel raised the nonce by at least one");
        assertLe(moved - before, MAX_STEP, "the step is at most 2^128");
    }
}
