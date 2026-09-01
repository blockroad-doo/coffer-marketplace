// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// Rows L3, L6, O3 and O5 of marketplace_gaps.md, plus the expiry boundary.
//
// A signature lives until its nonce moves. Four of the conditions that make a fill revert are
// reversible, and the contract holds no memory of them: when the condition goes away the same
// signature at the same nonce fills again. The off-chain store depends on that, it hides those rows
// at read time instead of retiring them, so these tests are what make "hide, never retire" a
// property of the contract rather than a claim about it.
//
// The boundary test pins _validateTrade's inequality (CofferMarketplace.sol:498). The contract
// allows block.timestamp == expiration; the backend's read gate uses expiration > now and hides
// the row one second early, which is the safe direction and only safe if the contract really
// does fill at the boundary second.
contract VerifyReversibleConditionsTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    uint256 constant SELLER_PK = 0xA11CE;
    uint256 constant BUYER_PK = 0xB0B;

    address public seller;
    address public buyer;
    address public outsider = makeAddr("outsider");
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    // Every bond in this file carries the mock's default maturity, and every signed message is priced at
    // that same value, so the profit is zero and the fee is zero. These tests are about a
    // condition reversing, and a fee term would only add arithmetic to the assertions.
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

    // ───── Row L3: the seller grants the approval again ─────

    // A revoke makes every listing of that seller revert, and a re-grant brings them all back. The
    // signature is untouched throughout and the nonce never moves, which is why the book revives a
    // retired listing on a re-post rather than asking for a new signature.
    function test_regrantedApproval_revivesListing() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondA);
        bytes memory sig = _signListing(SELLER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), false);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.MarketplaceNotApproved.selector);
        marketplace.buySignedListing{value: PRICE}(bondA, seller, PRICE, MATURITY, exp, nonce, 0, sig);

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        assertEq(marketplace.sListingNonce(seller, bondA), nonce, "revoke must not move the nonce");

        vm.prank(buyer);
        marketplace.buySignedListing{value: PRICE}(bondA, seller, PRICE, MATURITY, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondA), buyer, "the same signature fills after the re-grant");
    }

    // ───── Row L6: the seller gets the bond back ─────

    // The listing dies while the bond is elsewhere and revives when it returns. setApprovalForAll is
    // per owner and operator rather than per token, so the seller's approval survives the round trip
    // and nothing else has to be redone.
    function test_bondReturned_revivesListing() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondA);
        bytes memory sig = _signListing(SELLER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        vm.prank(seller);
        bondNft.transferFrom(seller, outsider, bondA);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.SellerNoLongerOwnsNft.selector);
        marketplace.buySignedListing{value: PRICE}(bondA, seller, PRICE, MATURITY, exp, nonce, 0, sig);

        vm.prank(outsider);
        bondNft.transferFrom(outsider, seller, bondA);

        assertEq(marketplace.sListingNonce(seller, bondA), nonce, "the round trip must not move the nonce");

        vm.prank(buyer);
        marketplace.buySignedListing{value: PRICE}(bondA, seller, PRICE, MATURITY, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondA), buyer, "the same signature fills after the bond returns");
    }

    // ───── Row O3: the maker's WETH comes back ─────

    // The funds condition is checked inside the fill and nowhere else, so an offer is dead exactly
    // as long as the money is gone. This is why the funds mirror hides rather than retires: a
    // shortage that heals leaves a signature that works again.
    function test_wethRestored_revivesOffer() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondA);
        bytes memory sig = _signOffer(BUYER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        uint256 held = weth.balanceOf(buyer);
        vm.prank(buyer);
        require(weth.transfer(outsider, held), "transfer failed");

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.acceptSignedOffer(bondA, buyer, PRICE, MATURITY, exp, nonce, 0, sig);

        vm.prank(outsider);
        require(weth.transfer(buyer, held), "transfer failed");

        assertEq(marketplace.sOfferNonce(buyer, bondA), nonce, "the shortage must not move the nonce");

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondA, buyer, PRICE, MATURITY, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondA), buyer, "the same signature fills once the funds return");
    }

    // ───── Row O5: one balance behind many offers ─────

    // Five live bids over one balance that covers exactly one of them. Every signature is valid and
    // every offer is genuinely fillable until one of them settles, which is why the book serves all
    // five and the funds gate measures each offer against the balance on its own rather than
    // summing them. Oversubscription is the design, not a defect.
    function test_oversubscribedBalance_exactlyOneFills() public {
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256[] memory bonds = new uint256[](5);
        bytes[] memory sigs = new bytes[](5);
        uint256[] memory nonces = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            bonds[i] = bondNft.mintTo(seller, address(coffer));
            nonces[i] = marketplace.sOfferNonce(buyer, bonds[i]);
            sigs[i] = _signOffer(BUYER_PK, bonds[i], PRICE, MATURITY, exp, nonces[i], 0);
        }

        // Leave the maker with exactly one offer's worth. The allowance stays unlimited, so the
        // balance limb is the only thing that can refuse the other four.
        uint256 held = weth.balanceOf(buyer);
        vm.prank(buyer);
        require(weth.transfer(outsider, held - PRICE), "transfer failed");
        assertEq(weth.balanceOf(buyer), PRICE, "the maker covers exactly one bid");

        vm.prank(seller);
        marketplace.acceptSignedOffer(bonds[0], buyer, PRICE, MATURITY, exp, nonces[0], 0, sigs[0]);
        assertEq(bondNft.ownerOf(bonds[0]), buyer, "the first bid settles");

        for (uint256 i = 1; i < 5; i++) {
            vm.prank(seller);
            vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
            marketplace.acceptSignedOffer(bonds[i], buyer, PRICE, MATURITY, exp, nonces[i], 0, sigs[i]);
            assertEq(bondNft.ownerOf(bonds[i]), seller, "the other bids move nothing");
            assertEq(marketplace.sOfferNonce(buyer, bonds[i]), nonces[i], "and consume no nonce");
        }
    }

    // ───── The expiry boundary ─────

    // _validateTrade allows block.timestamp <= expiration, so the expiration second is still a
    // fillable second and the one after it is not. Two bonds rather than one snapshot: the fill
    // moves a nonce, so the two halves need separate listings to stay independent.
    function test_expiryBoundary_fillsAtExpirationExactly() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonceA = marketplace.sListingNonce(seller, bondA);
        uint256 nonceB = marketplace.sListingNonce(seller, bondB);
        bytes memory sigA = _signListing(SELLER_PK, bondA, PRICE, MATURITY, exp, nonceA, 0);
        bytes memory sigB = _signListing(SELLER_PK, bondB, PRICE, MATURITY, exp, nonceB, 0);

        vm.warp(exp);
        vm.prank(buyer);
        marketplace.buySignedListing{value: PRICE}(bondA, seller, PRICE, MATURITY, exp, nonceA, 0, sigA);
        assertEq(bondNft.ownerOf(bondA), buyer, "the expiration second still fills");

        vm.warp(uint256(exp) + 1);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.buySignedListing{value: PRICE}(bondB, seller, PRICE, MATURITY, exp, nonceB, 0, sigB);
        assertEq(bondNft.ownerOf(bondB), seller, "the second after it does not");
    }
}
