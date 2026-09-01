//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

// Durable regression for M-01 (offer-path maturity collapse) and its listing-path sibling.
//
// The bond maturity observed at signing time is bound into the EIP-712 Listing and Offer structs
// and re-checked against the live bond maturity at fill. Collapsing a bond's maturity after a
// listing or offer is signed therefore makes the fill revert with MaturityValueMismatch instead of letting the
// counterparty overpay for a depleted bond. The signed value cannot be forged because it is part of
// the digest, and a still-zero bond is rejected by the BondNotOutstanding check on the live value.
//
// Run: forge test --match-path "test/unit/VerifyMaturityBinding.t.sol" -vv

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

contract VerifyMaturityBindingTest is Test {
    CofferMarketplace internal marketplace;
    MockBondNft internal bondNft;
    MockCoffer internal coffer;
    MockWETH internal weth;

    uint256 internal constant SELLER_PK = 0xA11CE;
    uint256 internal constant BUYER_PK = 0xB0B;

    address internal seller;
    address internal buyer;
    address internal mpOwner = makeAddr("mpOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    uint256 internal bondId;

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

    function _signListing(uint256 pk, uint128 price, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(LISTING_TYPEHASH, bondId, price, mat, exp, nonce, gNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(uint256 pk, uint128 amount, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, bondId, amount, mat, exp, nonce, gNonce));
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

        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        weth.mint(buyer, 100 ether);
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);
    }

    /// @notice M-01 core: the holder (who is also the offer taker) collapses the bond's maturity
    ///         after the maker signs, then accepts. The fill reverts instead of making the maker overpay.
    function test_offerPath_maturityCollapse_reverts() public {
        coffer.setMaturityValue(10 ether);
        uint128 wethAmount = 9 ether;
        uint64 exp = uint64(block.timestamp + 7 days);
        // The maker signs against the live 10-ether maturity.
        bytes memory sig = _signOffer(BUYER_PK, wethAmount, 10 ether, exp, 0, 0);

        // The holder collapses the bond to a husk after the offer is signed.
        coffer.setMaturityValue(1);

        // The taker must pass the signed maturity (10 ether) for the signature to verify, but the live
        // value is now 1, so the exact-match check reverts.
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.MaturityValueMismatch.selector);
        marketplace.acceptSignedOffer(bondId, buyer, wethAmount, 10 ether, exp, 0, 0, sig);
    }

    /// @notice Listing-path sibling: the seller front-runs the buyer's purchase with a maturity collapse.
    function test_listingPath_maturityFrontrun_reverts() public {
        coffer.setMaturityValue(10 ether);
        uint128 price = 9 ether;
        uint64 exp = uint64(block.timestamp + 7 days);
        bytes memory sig = _signListing(SELLER_PK, price, 10 ether, exp, 0, 0);

        // The seller collapses maturity between the buyer's broadcast and execution.
        coffer.setMaturityValue(1);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.MaturityValueMismatch.selector);
        marketplace.buySignedListing{value: price + 1 ether}(bondId, seller, price, 10 ether, exp, 0, 0, sig);
    }

    /// @notice Happy path offer: unchanged maturity settles and the profit-based WETH fee is charged.
    function test_offerPath_unchangedMaturity_settles() public {
        coffer.setMaturityValue(10 ether);
        uint128 wethAmount = 9 ether;
        uint64 exp = uint64(block.timestamp + 7 days);
        bytes memory sig = _signOffer(BUYER_PK, wethAmount, 10 ether, exp, 0, 0);

        uint256 sellerWethBefore = weth.balanceOf(seller);
        uint256 feeBefore = weth.balanceOf(address(marketplace));

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, wethAmount, 10 ether, exp, 0, 0, sig);

        // revenue = 10 - 9 = 1 ether, fee = 1 ether * 900 / 10000 = 0.09 ether.
        assertEq(bondNft.ownerOf(bondId), buyer, "buyer received the bond");
        assertEq(weth.balanceOf(seller) - sellerWethBefore, wethAmount, "seller received the full WETH amount");
        assertEq(weth.balanceOf(address(marketplace)) - feeBefore, 0.09 ether, "profit-based WETH fee charged");
    }

    /// @notice Happy path listing: unchanged maturity settles and the profit-based ETH fee is charged.
    function test_listingPath_unchangedMaturity_settles() public {
        coffer.setMaturityValue(10 ether);
        uint128 price = 9 ether;
        uint64 exp = uint64(block.timestamp + 7 days);
        bytes memory sig = _signListing(SELLER_PK, price, 10 ether, exp, 0, 0);

        uint256 feeBefore = address(marketplace).balance;

        // profit = 10 - 9 = 1 ether, fee = 0.09 ether. Buyer pays price + fee.
        vm.prank(buyer);
        marketplace.buySignedListing{value: price + 0.09 ether}(bondId, seller, price, 10 ether, exp, 0, 0, sig);

        assertEq(bondNft.ownerOf(bondId), buyer, "buyer received the bond");
        assertEq(address(marketplace).balance - feeBefore, 0.09 ether, "profit-based ETH fee charged");
    }

    /// @notice The signed maturityValue is part of the EIP-712 digest, so a taker cannot forge it: a
    ///         calldata value different from what was signed fails signature verification.
    function test_maturityValue_boundIntoDigest() public {
        coffer.setMaturityValue(10 ether);
        uint128 price = 9 ether;
        uint64 exp = uint64(block.timestamp + 7 days);
        // Signed against 10 ether.
        bytes memory sig = _signListing(SELLER_PK, price, 10 ether, exp, 0, 0);

        // Caller passes 8 ether. The live value is still 10 (no collapse), but the signature was over
        // 10 ether, so the reconstructed digest is wrong and verification fails before any value check.
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: price + 1 ether}(bondId, seller, price, 8 ether, exp, 0, 0, sig);
    }
}
