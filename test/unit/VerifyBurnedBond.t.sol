// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// The burn path of rows L10 and O8 in marketplace_gaps.md.
//
// Both rows say a burned bond fails inside ownerOf with ERC721NonexistentToken, before the
// marketplace reaches its own BondNotOutstanding check, and that BondNotOutstanding is therefore
// unreachable against the real Coffer. The reason is that the real Coffer deletes the holder record
// and burns the NFT in one call (coffer-smart-contracts/src/Coffer.sol:699-700), so the state where
// the maturity reads zero while the token still exists is never produced.
//
// Two tests take the burn path on each side, and a third produces the unreachable state by hand to
// show the two are genuinely different reverts. Without that third test the first two would only
// show that something reverts, not that the guard the rows name is the one that fires.
contract VerifyBurnedBondTest is Test {
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

    uint128 constant MATURITY = 1 ether;
    uint128 constant PRICE = 1 ether;

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

    // ───── Row L10, the burn half ─────

    // buySignedListing reads ownerOf at CofferMarketplace.sol:352, five statements before it asks
    // the coffer for a maturity at :361. A burned token has no owner, so the read itself reverts and
    // the marketplace never forms an opinion.
    function test_burnedBond_listingRevertsInOwnerOf() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondA);
        bytes memory sig = _signListing(SELLER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        bondNft.burn(bondA);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, bondA));
        marketplace.buySignedListing{value: PRICE}(bondA, seller, PRICE, MATURITY, exp, nonce, 0, sig);
    }

    // ───── Row O8, the burn half ─────

    // acceptSignedOffer reads ownerOf at :434 for its own NotOwner check, so the offer side fails in
    // the same place and for the same reason.
    function test_burnedBond_offerRevertsInOwnerOf() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondA);
        bytes memory sig = _signOffer(BUYER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        bondNft.burn(bondA);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, bondA));
        marketplace.acceptSignedOffer(bondA, buyer, PRICE, MATURITY, exp, nonce, 0, sig);

        assertEq(weth.balanceOf(seller), 0, "no WETH moved");
    }

    // ───── The state the real Coffer never produces ─────

    // Zero the maturity while leaving the token alive, which the mock can do and the real Coffer
    // cannot. BondNotOutstanding is what answers, which is a different error from the two tests
    // above. That difference is the whole content of the rows' claim: the burn path and the
    // zero-maturity path are distinguishable, and only the first one is reachable, so
    // BondNotOutstanding is dead code against the real Coffer rather than a case the book must serve.
    function test_zeroedMaturityWithLiveNft_isTheUnreachableState() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondB);
        bytes memory sig = _signListing(SELLER_PK, bondB, PRICE, MATURITY, exp, nonce, 0);

        coffer.setMaturityValueFor(bondB, 0);
        assertEq(bondNft.ownerOf(bondB), seller, "the token is still alive, which is what the real Coffer rules out");

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.buySignedListing{value: PRICE}(bondB, seller, PRICE, MATURITY, exp, nonce, 0, sig);
    }
}
