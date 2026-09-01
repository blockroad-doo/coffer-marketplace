// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";
import {MockBondNft, MockCoffer, MockWETH} from "./CofferMarketplace.t.sol";

// ───── Delegate mocks ─────
//
// A delegate recovers to address(this), NOT to an owner written in a constructor. Delegated code
// runs in the authorising account's context over that account's storage, which is empty, so a
// constructor-set owner would read as the zero address and the wallet would refuse every signature
// for a reason that has nothing to do with the branch under test. address(this) is the delegating
// EOA, so recovering to it is the same question the real 7702 accounts ask.

/// @dev The common shape: validates the account's own ECDSA signature and accepts NFTs.
contract Mock7702Delegate {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        if (err == ECDSA.RecoverError.NoError && recovered == address(this)) return MAGIC;
        return INVALID;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {}
}

/// @dev No isValidSignature at all and no fallback, so the ERC-1271 staticcall reverts. This is the
///      delegate that kills every signed message its authoriser ever signed.
contract Mock7702NoSigDelegate {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {}
}

/// @dev Answers ERC-1271 but implements no receiver hook, which is row O12: the signature verifies,
///      the WETH moves, and the final NFT transfer is what reverts.
contract Mock7702NoReceiverDelegate {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        if (err == ECDSA.RecoverError.NoError && recovered == address(this)) return MAGIC;
        return INVALID;
    }

    receive() external payable {}
}

// Rows L11, O10 and O12 of marketplace_gaps.md: a maker whose address carries code.
//
// SignatureChecker branches on one fact, signer.code.length == 0 (SignatureChecker.sol:49). An
// EIP-7702 delegation flips a plain EOA to the other side of that branch after the signature was
// already made, and whether the old signed messages survive is entirely the delegate's decision. Gap B
// turns down two cheaper designs, hiding every code-bearing maker's rows and refusing them at intake,
// on the grounds that the usual delegate validates its owner's ECDSA signature and keeps the rows
// alive. The accepting-delegate tests below are what make that a result instead of a belief.
//
// Code is placed with vm.etch rather than the 7702 cheatcode for all but one test. vm.etch is
// deterministic and assumes nothing about cheatcode lifetime, while attachDelegation designates the
// NEXT call an EIP-7702 transaction (Vm.sol:1188) and these tests need the code live when a
// different actor calls the marketplace later. One test uses the real cheatcode to pin the
// designator path. vm.etch leaves EXTCODESIZE at the delegate's own length rather than 7702's 23
// bytes, which the marketplace cannot observe: it never reads code size beyond "is it zero".
contract VerifyDelegatedMakersTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    Mock7702Delegate public accepting;
    Mock7702NoSigDelegate public silent;
    Mock7702NoReceiverDelegate public noReceiver;

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

    /// @dev Puts real delegate code at an EOA. See the contract comment for why this rather than the
    ///      7702 cheatcode, and for the one thing it does not reproduce.
    function _delegateTo(address account, address impl) internal {
        vm.etch(account, impl.code);
    }

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();
        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        accepting = new Mock7702Delegate();
        silent = new Mock7702NoSigDelegate();
        noReceiver = new Mock7702NoReceiverDelegate();

        seller = vm.addr(SELLER_PK);
        buyer = vm.addr(BUYER_PK);

        bondA = bondNft.mintTo(seller, address(coffer));
        bondB = bondNft.mintTo(seller, address(coffer));

        // Both approvals are granted while the accounts are still plain EOAs, exactly as a maker who
        // delegates later would have done. They are storage on the NFT and the WETH, so the
        // delegation does not disturb them.
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.deal(buyer, 100 ether);
        weth.mint(buyer, 100 ether);
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);
    }

    // ───── Row L11: the seller's address gains code after listing ─────

    // The signature was made by a key and is verified by code, and the code says yes. This is the
    // case Gap B protects: hiding every code-bearing maker's rows would have killed this listing
    // for no reason.
    function test_sellerGainsAcceptingDelegate_listingStillFills() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondA);
        bytes memory sig = _signListing(SELLER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        assertEq(seller.code.length, 0, "the seller signs as a plain EOA");
        _delegateTo(seller, address(accepting));
        assertGt(seller.code.length, 0, "and carries code by the time the fill runs");

        vm.prank(buyer);
        marketplace.buySignedListing{value: PRICE}(bondA, seller, PRICE, MATURITY, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondA), buyer, "the ERC-1271 branch accepted the key signature");
    }

    // The same delegation with a delegate that answers nothing. Every signed message this seller ever signed
    // is dead while the delegation stands, and no event anywhere reports it, which is why Gap B's
    // cycle re-asks instead of waiting to be told.
    function test_sellerGainsSilentDelegate_listingReverts() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondA);
        bytes memory sig = _signListing(SELLER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        _delegateTo(seller, address(silent));

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: PRICE}(bondA, seller, PRICE, MATURITY, exp, nonce, 0, sig);
    }

    // ───── Row O10: the offer maker's address gains code after signing ─────

    // The offer twin. The delegate answers the signature and receives the bond, so both pieces of
    // maker-controlled code in an accept are exercised in one fill.
    function test_offerMakerGainsAcceptingDelegate_offerStillFills() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondA);
        bytes memory sig = _signOffer(BUYER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        _delegateTo(buyer, address(accepting));

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondA, buyer, PRICE, MATURITY, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondA), buyer, "the delegate validated and received");
        assertEq(weth.balanceOf(seller), PRICE, "and the seller was paid");
    }

    function test_offerMakerGainsSilentDelegate_offerReverts() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondA);
        bytes memory sig = _signOffer(BUYER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        _delegateTo(buyer, address(silent));

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.acceptSignedOffer(bondA, buyer, PRICE, MATURITY, exp, nonce, 0, sig);
    }

    // ───── Row O12: the delegate has no receiver hook ─────

    // A valid signature, funded and approved, that no seller can ever accept. The revert arrives at
    // the last statement of _executeAccept (CofferMarketplace.sol:578), after the WETH checks have
    // passed, which is what makes this invisible to everything except the transfer itself.
    function test_delegateWithoutReceiver_acceptReverts() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondA);
        bytes memory sig = _signOffer(BUYER_PK, bondA, PRICE, MATURITY, exp, nonce, 0);

        _delegateTo(buyer, address(noReceiver));

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, buyer));
        marketplace.acceptSignedOffer(bondA, buyer, PRICE, MATURITY, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondA), seller, "nothing settled");
        assertEq(weth.balanceOf(seller), 0, "and the WETH did not move either, the fill is atomic");
    }

    // ───── The designator itself ─────

    // The tests above place code with vm.etch. This one uses the real cheatcode, so the branch is
    // reached through an actual EIP-7702 authorisation rather than an equivalent one. The
    // authorisation is signed by the seller and carried by the buyer's transaction, which is how
    // 7702 works: the authority signs, anyone may include it.
    function test_realDelegationDesignator_listingStillFills() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondB);
        bytes memory sig = _signListing(SELLER_PK, bondB, PRICE, MATURITY, exp, nonce, 0);

        vm.signAndAttachDelegation(address(accepting), SELLER_PK);

        vm.prank(buyer);
        marketplace.buySignedListing{value: PRICE}(bondB, seller, PRICE, MATURITY, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondB), buyer, "the designator resolved to the delegate");
    }
}
