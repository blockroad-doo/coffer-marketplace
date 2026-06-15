// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// Durable regression suite for audit finding L-04.
// The buy path now performs the same isApprovedForAll fast-fail as the accept path, and both trade
// functions run the cheap local checks and the on-chain ownership and approval checks before signature
// verification. A revoked-approval order therefore reverts MarketplaceNotApproved early, with a named
// error, before any signature work, rather than reverting late inside safeTransferFrom.
contract VerifyApprovalFastFailTest is Test {
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
    uint256 public bondId;

    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant OFFER_TYPEHASH = keccak256(
        "Offer(uint256 bondId,uint128 wethAmount,uint128 maturityValue,uint64 expiration,uint256 maxFee,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

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
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, bId, wAmt, mat, exp, maxF, nonce, gNonce));
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

        bondId = bondNft.mintTo(seller, address(coffer));

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.deal(buyer, 100 ether);
        weth.mint(buyer, 100 ether);
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);
    }

    // A seller signs a valid listing, then revokes the marketplace's operator approval. The buy reverts
    // with the named MarketplaceNotApproved, not the bond NFT's own transfer error.
    function test_buy_revokedApproval_revertsMarketplaceNotApproved() public {
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, 1 ether, exp, nonce, 0);

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), false);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.MarketplaceNotApproved.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, 1 ether, exp, nonce, 0, 0, sig);
    }

    // The approval check runs before signature verification: even with an empty signature, a fill on an
    // unapproved listing reverts MarketplaceNotApproved rather than InvalidSignature.
    function test_buy_failsFast_approvalCheckedBeforeSignature() public {
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), false);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.MarketplaceNotApproved.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, 1 ether, exp, nonce, 0, 0, "");
    }

    // The same fast-fail already holds on the accept path: the owner revokes approval after the offerer
    // signs, and acceptSignedOffer reverts MarketplaceNotApproved.
    function test_accept_revokedApproval_revertsMarketplaceNotApproved() public {
        uint128 amount = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, amount, 1 ether, exp, type(uint256).max, nonce, 0);

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), false);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.MarketplaceNotApproved.selector);
        marketplace.acceptSignedOffer(bondId, buyer, amount, 1 ether, exp, type(uint256).max, nonce, 0, sig);
    }
}
