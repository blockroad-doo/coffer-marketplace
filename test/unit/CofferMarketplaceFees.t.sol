//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract MockBondNft {
    mapping(uint256 => address) private _owners;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => address) private _coffers;
    uint256 public sBondIdCounter;

    function mintTo(address to, address coffer) external returns (uint256) {
        uint256 id = ++sBondIdCounter;
        _owners[id] = to;
        _coffers[id] = coffer;
        return id;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "ERC721: nonexistent token");
        return owner;
    }

    function cofferOf(uint256 tokenId) external view returns (address) {
        return _coffers[tokenId];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_owners[tokenId] == from, "ERC721: not owner");
        require(msg.sender == from || _operatorApprovals[from][msg.sender], "ERC721: not approved");
        _owners[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "ERC721: unsafe recipient"
            );
        }
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }
}

contract MockCoffer {
    uint128 public maturityValue = 10 ether;
    uint32 public duration = 86400;
    uint32 public startTs;

    constructor() {
        startTs = uint32(block.timestamp - 86401);
    }

    function sHolderConditions(uint256) external view returns (uint128, uint32, uint32) {
        return (maturityValue, duration, startTs);
    }

    function setMaturityValue(uint128 _val) external {
        maturityValue = _val;
    }
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "WETH: bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "WETH: bal");
        require(allowance[from][msg.sender] >= amount, "WETH: allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CofferMarketplaceFeesTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    uint256 constant SELLER_PK = 0xA11CE;
    uint256 constant BUYER_PK = 0xB0B;

    address public seller;
    address public buyer;
    address public nonOwner = makeAddr("nonOwner");
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public bondId;

    // ───── EIP-712 Helpers ─────

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

    function _listingDigest(
        address maker,
        uint256 bId,
        uint128 pr,
        uint128 mat,
        uint64 exp,
        uint256 nonce,
        uint256 gNonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(LISTING_TYPEHASH, maker, bId, pr, mat, exp, nonce, gNonce));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _offerDigest(
        address maker,
        uint256 bId,
        uint128 wAmt,
        uint128 mat,
        uint64 exp,
        uint256 nonce,
        uint256 gNonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, maker, bId, wAmt, mat, exp, nonce, gNonce));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signListing(uint256 pk, uint256 bId, uint128 pr, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _listingDigest(vm.addr(pk), bId, pr, mat, exp, nonce, gNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(uint256 pk, uint256 bId, uint128 wAmt, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _offerDigest(vm.addr(pk), bId, wAmt, mat, exp, nonce, gNonce);
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

    /// @dev The fee the contract charges on a profit, from its published constants.
    function _fee(uint256 profit) internal view returns (uint256) {
        return (profit * marketplace.FEE_BPS()) / marketplace.BPS_DENOMINATOR();
    }

    // ───── Admin: setFeeRecipient ─────

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(mpOwner);
        marketplace.setFeeRecipient(newRecipient);
        assertEq(marketplace.sFeeRecipient(), newRecipient);
    }

    function test_setFeeRecipient_revert_notOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        marketplace.setFeeRecipient(makeAddr("x"));
    }

    function test_setFeeRecipient_revert_zeroAddress() public {
        vm.prank(mpOwner);
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        marketplace.setFeeRecipient(address(0));
    }

    // ───── Constants ─────

    /// @notice The rate is published on-chain, so a client computes the fee from the contract
    ///         rather than from its own copy of the number.
    function test_feeBpsConstantIsPublished() public view {
        assertEq(marketplace.FEE_BPS(), 900, "published fee in basis points");
        assertEq(marketplace.BPS_DENOMINATOR(), 10000, "published basis points denominator");
    }

    // ───── Admin: Ownable2Step transfer ─────

    function test_ownable2Step_transfer() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(mpOwner);
        marketplace.transferOwnership(newOwner);

        assertEq(marketplace.owner(), mpOwner);
        assertEq(marketplace.pendingOwner(), newOwner);

        vm.prank(newOwner);
        marketplace.acceptOwnership();
        assertEq(marketplace.owner(), newOwner);
    }

    // ───── Claim: ETH ─────

    function test_claimFees_revert_nothingToClaim() public {
        vm.prank(mpOwner);
        vm.expectRevert(CofferMarketplace.NothingToClaim.selector);
        marketplace.claimFees();
    }

    function test_claimFees_revert_notOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        marketplace.claimFees();
    }

    function test_claimFees_afterBuySignedListingFee() public {
        uint128 price = 1 ether;
        coffer.setMaturityValue(2 ether); // profit = 1 ether
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValue();
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        uint256 expectedFee = _fee(1 ether);
        vm.prank(buyer);
        marketplace.buySignedListing{value: uint256(price) + expectedFee}(
            bondId, seller, price, mat, exp, nonce, 0, sig
        );

        assertEq(address(marketplace).balance, expectedFee);

        uint256 recipBefore = feeRecipient.balance;
        vm.prank(mpOwner);
        marketplace.claimFees();
        assertEq(feeRecipient.balance - recipBefore, expectedFee);
        assertEq(address(marketplace).balance, 0);
    }

    // ───── Claim: WETH ─────

    function test_claimWethFees_revert_nothingToClaim() public {
        vm.prank(mpOwner);
        vm.expectRevert(CofferMarketplace.NothingToClaimWeth.selector);
        marketplace.claimWethFees();
    }

    function test_claimWethFees_revert_notOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        marketplace.claimWethFees();
    }

    // ───── Fee math: buySignedListing (profit-based) ─────

    function test_buySignedListing_chargesProfitFee() public {
        uint128 price = 1 ether;
        coffer.setMaturityValue(2 ether); // profit = 1 ether
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValue();
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        // Fee = profit * FEE_BPS / BPS_DENOMINATOR = 1 ether * 900 / 10000 = 0.09 ether
        uint256 expectedBuyFee = _fee(1 ether);
        uint256 sellerBefore = seller.balance;
        uint256 buyerBefore = buyer.balance;
        uint256 mktBefore = address(marketplace).balance;

        vm.prank(buyer);
        marketplace.buySignedListing{value: price + expectedBuyFee}(bondId, seller, price, mat, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(seller.balance - sellerBefore, price);
        assertEq(address(marketplace).balance - mktBefore, expectedBuyFee);
        assertEq(buyerBefore - buyer.balance, price + expectedBuyFee);
    }

    function test_buySignedListing_noProfit_chargesNothing() public {
        uint128 price = 10 ether; // >= maturityValue
        coffer.setMaturityValue(5 ether);
        weth.mint(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValue();
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        // With no profit and no fixed component, the fee is exactly zero.
        vm.prank(buyer);
        marketplace.buySignedListing{value: uint256(price)}(bondId, seller, price, mat, exp, nonce, 0, sig);
        assertEq(address(marketplace).balance, 0);
    }

    function test_buySignedListing_revert_insufficientPaymentForFee() public {
        uint128 price = 1 ether;
        coffer.setMaturityValue(2 ether);
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint128 mat = coffer.maturityValue();
        bytes memory sig = _signListing(SELLER_PK, bondId, price, mat, exp, nonce, 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, mat, exp, nonce, 0, sig);
    }

    // ───── Fee math: acceptSignedOffer (profit-based) ─────

    function test_acceptSignedOffer_chargesProfitFee() public {
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether); // revenue = 1 ether
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        uint128 mat = coffer.maturityValue();
        bytes memory sig = _signOffer(BUYER_PK, bondId, offerAmount, mat, exp, nonce, 0);

        uint256 expectedFee = _fee(1 ether);
        uint256 sellerWethBefore = weth.balanceOf(seller);
        uint256 buyerWethBefore = weth.balanceOf(buyer);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, mat, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(weth.balanceOf(seller) - sellerWethBefore, offerAmount);
        assertEq(buyerWethBefore - weth.balanceOf(buyer), uint256(offerAmount) + expectedFee);
        assertEq(weth.balanceOf(address(marketplace)), expectedFee);
    }

    // ───── Non-payable: acceptSignedOffer rejects ETH ─────

    function test_acceptSignedOffer_rejectsSentEth() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        uint128 mat = coffer.maturityValue();
        bytes memory sig = _signOffer(BUYER_PK, bondId, 1 ether, mat, exp, nonce, 0);

        vm.prank(seller);
        vm.deal(seller, 1 ether);
        (bool ok,) = address(marketplace).call{value: 1}(
            abi.encodeWithSelector(
                marketplace.acceptSignedOffer.selector,
                bondId,
                buyer,
                uint128(1 ether),
                mat,
                exp,
                nonce,
                uint256(0),
                sig
            )
        );
        assertFalse(ok);
    }

    // ───── Claim: WETH happy path ─────

    function test_claimWethFees_afterAcceptSignedOfferFee() public {
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether);
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        uint128 mat = coffer.maturityValue();
        bytes memory sig = _signOffer(BUYER_PK, bondId, offerAmount, mat, exp, nonce, 0);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, mat, exp, nonce, 0, sig);

        uint256 expectedFee = _fee(1 ether);
        assertEq(weth.balanceOf(address(marketplace)), expectedFee);

        uint256 recipBefore = weth.balanceOf(feeRecipient);
        vm.prank(mpOwner);
        marketplace.claimWethFees();

        assertEq(weth.balanceOf(feeRecipient) - recipBefore, expectedFee);
        assertEq(weth.balanceOf(address(marketplace)), 0);
    }
}
