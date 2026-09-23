// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// Gap row MG-05 (RD-01 boundary and monotone clauses, RD-03, ADV-10, SPEC-03).
//
// Stateless fuzzes of the one rounding site. The fee is floor(profit * 900 / 10000) on both paths: never
// rounded up, less than one wei short of exact, zero exactly when the profit is at most 11 wei, strictly
// below a positive profit, non-decreasing in the profit, the same on both paths, and free of overflow over
// the whole uint128 x uint128 domain on the offer side. Formula-free bounds beside it: the taker's outlay
// never exceeds max(paid, maturity), and a full-balance msg.value is refunded to the wei. The fills fund the
// taker with paid + maturity, which covers any fee without using the formula, and read the fee back from
// the marketplace's balance.
contract VerifyFeeScheduleTest is Test {
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
    uint64 public expiration;

    bytes32 constant LISTING_TYPEHASH = keccak256(
        "Listing(address seller,uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant OFFER_TYPEHASH = keccak256(
        "Offer(address buyer,uint256 bondId,uint128 wethAmount,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

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
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);
        expiration = uint64(block.timestamp + 1 days);
    }

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

    /// @dev The contract's formula, from its published constants, for the tests that fund exactly.
    function _fee(uint256 profit) internal view returns (uint256) {
        return (profit * marketplace.FEE_BPS()) / marketplace.BPS_DENOMINATOR();
    }

    /// @dev Fill `id` at `price` sending the buyer's whole balance, funded to price + mat. Returns the buyer's
    ///      outlay (the refund netted) and the fee the marketplace kept.
    function _buy(uint256 id, uint128 price, uint128 mat) internal returns (uint256 outlay, uint256 fee) {
        uint256 nonce = marketplace.sListingNonce(seller, id);
        bytes memory sig = _signListing(SELLER_PK, id, price, mat, expiration, nonce, 0);
        uint256 fund = uint256(price) + uint256(mat);
        vm.deal(buyer, fund);
        uint256 mktBefore = address(marketplace).balance;

        vm.prank(buyer);
        marketplace.buySignedListing{value: fund}(id, seller, price, mat, expiration, nonce, 0, sig);

        outlay = fund - buyer.balance;
        fee = address(marketplace).balance - mktBefore;
    }

    /// @dev Accept an offer on `id` at `amount`, the offerer topped up by amount + mat.
    function _accept(uint256 id, uint128 amount, uint128 mat) internal returns (uint256 outlay, uint256 fee) {
        uint256 nonce = marketplace.sOfferNonce(buyer, id);
        bytes memory sig = _signOffer(BUYER_PK, id, amount, mat, expiration, nonce, 0);
        uint256 fund = uint256(amount) + uint256(mat);
        weth.mint(buyer, fund);
        uint256 buyerBefore = weth.balanceOf(buyer);
        uint256 mktBefore = weth.balanceOf(address(marketplace));

        vm.prank(seller);
        marketplace.acceptSignedOffer(id, buyer, amount, mat, expiration, nonce, 0, sig);

        outlay = buyerBefore - weth.balanceOf(buyer);
        fee = weth.balanceOf(address(marketplace)) - mktBefore;
    }

    function _fill(bool offerSide, uint256 id, uint128 paid, uint128 mat) internal returns (uint256, uint256) {
        if (offerSide) return _accept(id, paid, mat);
        return _buy(id, paid, mat);
    }

    function _assertFloor(uint256 profit, uint256 fee) internal pure {
        assertLe(fee * 10000, profit * 900, "fee rounded up");
        assertLt(profit * 900, fee * 10000 + 10000, "fee more than one wei short of exact");
        assertEq(fee == 0, profit <= 11, "zero-fee boundary is not profit <= 11 wei");
        if (profit > 0) assertLt(fee, profit, "fee not below the profit");
    }

    /// @notice RD-03, ADV-10: the offer side over the whole domain, the offerer holding exactly amount + fee.
    ///         Neither profit * FEE_BPS nor amount + fee overflows, and the exact balance settles.
    function testFuzz_feeAcceptSigned_profitRange_noOverflow(uint128 maturity, uint128 amount) public {
        maturity = uint128(bound(maturity, 1, type(uint128).max));
        amount = uint128(bound(amount, 1, type(uint128).max));
        coffer.setMaturityValue(maturity);
        uint256 profit = maturity > amount ? uint256(maturity) - amount : 0;
        uint256 fee = _fee(profit);
        weth.mint(buyer, uint256(amount) + fee);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondA);
        bytes memory sig = _signOffer(BUYER_PK, bondA, amount, maturity, expiration, nonce, 0);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondA, buyer, amount, maturity, expiration, nonce, 0, sig);

        assertEq(weth.balanceOf(buyer), 0, "the exact balance is fully consumed");
        assertEq(weth.balanceOf(seller), amount);
        assertEq(weth.balanceOf(address(marketplace)), fee);
        assertEq(bondNft.ownerOf(bondA), buyer);
    }

    /// @notice RD-01: the floor identity on both paths, the fee read from the balance delta.
    function testFuzz_feeFloorIdentity(uint128 maturity, uint128 paid, bool offerSide) public {
        maturity = uint128(bound(maturity, 1, type(uint128).max));
        paid = uint128(bound(paid, 1, maturity));
        coffer.setMaturityValue(maturity);
        (, uint256 fee) = _fill(offerSide, bondA, paid, maturity);
        _assertFloor(uint256(maturity) - paid, fee);
    }

    /// @notice The 11-wei boundary itself, which the wide domain reaches only by chance.
    function testFuzz_feeZeroIffProfitAtMost11(uint8 profitWei, bool offerSide) public {
        uint256 profit = bound(uint256(profitWei), 0, 40);
        uint128 maturity = 1 ether; // the shared mock's default
        (, uint256 fee) = _fill(offerSide, bondA, uint128(1 ether - profit), maturity);
        _assertFloor(profit, fee);
    }

    /// @notice RD-01, SPEC-03: on two bonds at one maturity a lower price never pays a lower fee and never
    ///         costs the taker more in total.
    function testFuzz_feeMonotone(uint128 maturity, uint128 p1, uint128 p2, bool offerSide) public {
        maturity = uint128(bound(maturity, 2, type(uint128).max));
        p1 = uint128(bound(p1, 1, maturity));
        p2 = uint128(bound(p2, p1, maturity)); // p1 <= p2, so profit1 >= profit2
        coffer.setMaturityValue(maturity);
        (uint256 outlay1, uint256 fee1) = _fill(offerSide, bondA, p1, maturity);
        (uint256 outlay2, uint256 fee2) = _fill(offerSide, bondB, p2, maturity);
        assertGe(fee1, fee2, "fee not monotone in the profit");
        assertLe(outlay1, outlay2, "a lower price cost the taker more");
    }

    /// @notice ADV-10: a full-balance msg.value is refunded to the wei.
    function testFuzz_buyFullBalanceRefund(uint128 maturity, uint128 price, uint256 extra) public {
        maturity = uint128(bound(maturity, 1, type(uint128).max));
        price = uint128(bound(price, 1, type(uint128).max));
        extra = bound(extra, 0, 1000 ether);
        coffer.setMaturityValue(maturity);
        uint256 fee = _fee(maturity > price ? uint256(maturity) - price : 0);
        uint256 nonce = marketplace.sListingNonce(seller, bondA);
        bytes memory sig = _signListing(SELLER_PK, bondA, price, maturity, expiration, nonce, 0);
        vm.deal(buyer, uint256(price) + fee + extra);

        vm.prank(buyer);
        marketplace.buySignedListing{value: buyer.balance}(bondA, seller, price, maturity, expiration, nonce, 0, sig);

        assertEq(buyer.balance, extra, "refund not to the wei");
        assertEq(seller.balance, price);
        assertEq(address(marketplace).balance, fee);
    }

    /// @notice SPEC-03: the outlay never exceeds max(paid, maturity), formula-free on both paths.
    function testFuzz_outlayNeverAboveFace(uint128 maturity, uint128 paid, bool offerSide) public {
        maturity = uint128(bound(maturity, 1, type(uint128).max));
        paid = uint128(bound(paid, 1, type(uint128).max));
        coffer.setMaturityValue(maturity);
        (uint256 outlay,) = _fill(offerSide, bondA, paid, maturity);
        uint256 cap = paid > maturity ? paid : maturity;
        assertGe(outlay, paid, "outlay below the price");
        assertLe(outlay, cap, "fee lifted the taker above face");
        if (paid >= maturity) assertEq(outlay, paid, "at or above face pays no fee");
        else assertLt(outlay, maturity, "below face must stay below face");
    }

    /// @notice RD-03: the same profit pays the same fee on both paths, a guard against a refactor that splits them.
    function testFuzz_feeSameOnBothPaths(uint128 maturity, uint128 paid) public {
        maturity = uint128(bound(maturity, 1, type(uint128).max));
        paid = uint128(bound(paid, 1, type(uint128).max));
        coffer.setMaturityValue(maturity);
        (, uint256 feeBuy) = _buy(bondA, paid, maturity);
        (, uint256 feeAccept) = _accept(bondB, paid, maturity);
        assertEq(feeBuy, feeAccept, "listing and offer fee differ for the same profit");
    }
}
