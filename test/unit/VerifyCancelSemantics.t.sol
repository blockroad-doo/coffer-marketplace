// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// Durable regression suite for audit finding L-03 (PoC F-04).
// A fill requires the signed nonce to equal the current per-bond nonce, and every fill or per-bond
// cancel advances that nonce by one. The integration rule is one open order per maker, bond, and side,
// signed at the current on-chain nonce. These tests pin the documented cancel semantics on-chain:
// the batch cancel with a repeated bond id clears a pre-signed queue atomically without touching other
// bonds, a single cancel arms the next pre-signed order (the footgun the docs warn about), and the
// global cancel sweeps every order across all bonds.
contract VerifyCancelSemanticsTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    uint256 constant SELLER_PK = 0xA11CE;
    uint256 constant BUYER_PK = 0xB0B;

    address public seller;
    address public buyer;
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");
    uint256 public bondA;
    uint256 public bondB;

    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant OFFER_TYPEHASH = keccak256(
        "Offer(uint256 bondId,uint128 wethAmount,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("CofferMarketplace")),
                keccak256(bytes("4")),
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
        bytes32 structHash = keccak256(abi.encode(LISTING_TYPEHASH, bId, pr, mat, exp, nonce, gNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(uint256 pk, uint256 bId, uint128 wAmt, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, bId, wAmt, mat, exp, nonce, gNonce));
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
        bondB = bondNft.mintTo(seller, address(coffer));

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.deal(buyer, 100 ether);
        weth.mint(buyer, 100 ether);
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);
    }

    // The seller pre-signed listings at nonce N and N+1 for bond A (violating the one-open-order rule)
    // and holds a normal listing on bond B. cancelListings([A, A]) advances bond A's nonce by two in
    // one transaction, killing the whole queue, while bond B's listing stays live and fillable.
    function test_batchCancelRepeatedBondId_clearsPresignedListingQueue() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonceA = marketplace.sListingNonce(seller, bondA);
        bytes memory sigA0 = _signListing(SELLER_PK, bondA, 1 ether, 1 ether, exp, nonceA, 0);
        bytes memory sigA1 = _signListing(SELLER_PK, bondA, 0.5 ether, 1 ether, exp, nonceA + 1, 0);
        uint256 nonceB = marketplace.sListingNonce(seller, bondB);
        bytes memory sigB = _signListing(SELLER_PK, bondB, 2 ether, 1 ether, exp, nonceB, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondA;
        ids[1] = bondA;
        vm.prank(seller);
        marketplace.cancelListings(ids);
        assertEq(marketplace.sListingNonce(seller, bondA), nonceA + 2, "nonce jumped past the whole queue");

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: 1 ether}(bondA, seller, 1 ether, 1 ether, exp, nonceA, 0, sigA0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: 0.5 ether}(bondA, seller, 0.5 ether, 1 ether, exp, nonceA + 1, 0, sigA1);

        vm.prank(buyer);
        marketplace.buySignedListing{value: 2 ether}(bondB, seller, 2 ether, 1 ether, exp, nonceB, 0, sigB);
        assertEq(bondNft.ownerOf(bondB), buyer, "bond B listing was untouched by the bond A queue clear");
        assertEq(bondNft.ownerOf(bondA), seller, "bond A was never sold");
    }

    // Offer mirror of the queue clear: cancelOffers([A, A]) kills both pre-signed offers on bond A and
    // leaves the offer on bond B acceptable.
    function test_batchCancelRepeatedBondId_clearsPresignedOfferQueue() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonceA = marketplace.sOfferNonce(buyer, bondA);
        bytes memory sigA0 = _signOffer(BUYER_PK, bondA, 1 ether, 1 ether, exp, nonceA, 0);
        bytes memory sigA1 = _signOffer(BUYER_PK, bondA, 0.5 ether, 1 ether, exp, nonceA + 1, 0);
        uint256 nonceB = marketplace.sOfferNonce(buyer, bondB);
        bytes memory sigB = _signOffer(BUYER_PK, bondB, 2 ether, 1 ether, exp, nonceB, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondA;
        ids[1] = bondA;
        vm.prank(buyer);
        marketplace.cancelOffers(ids);
        assertEq(marketplace.sOfferNonce(buyer, bondA), nonceA + 2, "nonce jumped past the whole queue");

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondA, buyer, 1 ether, 1 ether, exp, nonceA, 0, sigA0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondA, buyer, 0.5 ether, 1 ether, exp, nonceA + 1, 0, sigA1);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondB, buyer, 2 ether, 1 ether, exp, nonceB, 0, sigB);
        assertEq(bondNft.ownerOf(bondB), buyer, "bond B offer was untouched by the bond A queue clear");
    }

    // The footgun itself, kept as a living document: a single cancel advances the nonce by one, which
    // arms the pre-signed next-nonce offer. This is why a queue must be cleared with the batch cancel.
    function test_singleCancel_armsNextPresignedOffer() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonceA = marketplace.sOfferNonce(buyer, bondA);
        bytes memory sigA1 = _signOffer(BUYER_PK, bondA, 0.5 ether, 1 ether, exp, nonceA + 1, 0);

        vm.prank(buyer);
        marketplace.cancelOffer(bondA);
        assertEq(marketplace.sOfferNonce(buyer, bondA), nonceA + 1, "single cancel advances by one");

        // The pre-signed next-nonce offer is now live and the seller can take it.
        vm.prank(seller);
        marketplace.acceptSignedOffer(bondA, buyer, 0.5 ether, 1 ether, exp, nonceA + 1, 0, sigA1);
        assertEq(bondNft.ownerOf(bondA), buyer, "pre-signed next-nonce offer was armed by the cancel");
    }

    // The global cancel is the sweep: it kills offers across all bonds in one write without touching
    // the per-bond nonces.
    function test_cancelAllOffers_sweepsAcrossBonds() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 gNonce = marketplace.sGlobalOfferNonce(buyer);
        uint256 nonceA = marketplace.sOfferNonce(buyer, bondA);
        uint256 nonceB = marketplace.sOfferNonce(buyer, bondB);
        bytes memory sigA = _signOffer(BUYER_PK, bondA, 1 ether, 1 ether, exp, nonceA, gNonce);
        bytes memory sigB = _signOffer(BUYER_PK, bondB, 2 ether, 1 ether, exp, nonceB, gNonce);

        vm.prank(buyer);
        marketplace.cancelAllOffers();
        assertEq(marketplace.sGlobalOfferNonce(buyer), gNonce + 1, "global nonce bumped");
        assertEq(marketplace.sOfferNonce(buyer, bondA), nonceA, "per-bond nonce A untouched");
        assertEq(marketplace.sOfferNonce(buyer, bondB), nonceB, "per-bond nonce B untouched");

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondA, buyer, 1 ether, 1 ether, exp, nonceA, gNonce, sigA);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondB, buyer, 2 ether, 1 ether, exp, nonceB, gNonce, sigB);
    }
}
