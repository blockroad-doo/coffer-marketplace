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

    function sHolderConditions(uint256) external view returns (uint128, uint32, uint32, bool) {
        return (maturityValue, duration, startTs, false);
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

    uint16 constant PROFIT_BPS = 800; // 8%

    // ───── EIP-712 Helpers ─────

    bytes32 constant LISTING_TYPEHASH =
        keccak256("Listing(uint256 bondId,uint128 price,uint64 expiration,uint256 nonce,uint256 globalNonce)");
    bytes32 constant OFFER_TYPEHASH = keccak256(
        "Offer(uint256 bondId,uint128 wethAmount,uint64 expiration,uint256 maxFee,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("CofferMarketplace")),
                keccak256(bytes("2")),
                block.chainid,
                address(marketplace)
            )
        );
    }

    function _listingDigest(uint256 bId, uint128 pr, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(LISTING_TYPEHASH, bId, pr, exp, nonce, gNonce));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _offerDigest(uint256 bId, uint128 wAmt, uint64 exp, uint256 maxF, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, bId, wAmt, exp, maxF, nonce, gNonce));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signListing(uint256 pk, uint256 bId, uint128 pr, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _listingDigest(bId, pr, exp, nonce, gNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(uint256 pk, uint256 bId, uint128 wAmt, uint64 exp, uint256 maxF, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _offerDigest(bId, wAmt, exp, maxF, nonce, gNonce);
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

        _configureFees();
    }

    function _configureFees() internal {
        // The only protocol fee is a profit-based percentage on the two trade actions.
        vm.prank(mpOwner);
        marketplace.setFeeBps(PROFIT_BPS, PROFIT_BPS);
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

    // ───── Admin: setFeeBps ─────

    function test_setFeeBps() public {
        vm.prank(mpOwner);
        marketplace.setFeeBps(123, 456);
        assertEq(marketplace.sListingFeeBps(), 123);
        assertEq(marketplace.sOfferFeeBps(), 456);
    }

    function test_setFeeBps_revert_notOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        marketplace.setFeeBps(1, 1);
    }

    function test_setFeeBps_revert_listingBpsTooHigh() public {
        vm.prank(mpOwner);
        vm.expectRevert(CofferMarketplace.FeeTooHigh.selector);
        marketplace.setFeeBps(10000, 0);
    }

    function test_setFeeBps_revert_offerBpsTooHigh() public {
        vm.prank(mpOwner);
        vm.expectRevert(CofferMarketplace.FeeTooHigh.selector);
        marketplace.setFeeBps(0, 10000);
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
        bytes memory sig = _signListing(SELLER_PK, bondId, price, exp, nonce, 0);

        uint256 expectedFee = (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        vm.prank(buyer);
        marketplace.buySignedListing{value: uint256(price) + expectedFee}(
            bondId, seller, price, exp, nonce, 0, expectedFee, sig
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
        bytes memory sig = _signListing(SELLER_PK, bondId, price, exp, nonce, 0);

        // Fee = profit * bps / 10000 = 1 ether * 800 / 10000 = 0.08 ether
        uint256 expectedBuyFee = (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        uint256 sellerBefore = seller.balance;
        uint256 buyerBefore = buyer.balance;
        uint256 mktBefore = address(marketplace).balance;

        vm.prank(buyer);
        marketplace.buySignedListing{value: price + expectedBuyFee}(
            bondId, seller, price, exp, nonce, 0, expectedBuyFee, sig
        );

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
        bytes memory sig = _signListing(SELLER_PK, bondId, price, exp, nonce, 0);

        // With no profit and no fixed component, the fee is exactly zero.
        vm.prank(buyer);
        marketplace.buySignedListing{value: uint256(price)}(bondId, seller, price, exp, nonce, 0, 0, sig);
        assertEq(address(marketplace).balance, 0);
    }

    function test_buySignedListing_revert_feeExceedsMax() public {
        uint128 price = 1 ether;
        coffer.setMaturityValue(2 ether);
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, exp, nonce, 0);

        uint256 trueFee = (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.FeeExceedsMax.selector);
        marketplace.buySignedListing{value: price + trueFee}(bondId, seller, price, exp, nonce, 0, trueFee - 1, sig);
    }

    function test_buySignedListing_revert_insufficientPaymentForFee() public {
        uint128 price = 1 ether;
        coffer.setMaturityValue(2 ether);
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, exp, nonce, 0);

        uint256 trueFee = (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, exp, nonce, 0, trueFee, sig);
    }

    // ───── Fee math: acceptSignedOffer (profit-based, capped by signed max) ─────

    function test_acceptSignedOffer_chargesProfitFee() public {
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether); // revenue = 1 ether
        uint64 exp = uint64(block.timestamp + 1 days);

        // Offer with no fee cap
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, offerAmount, exp, type(uint256).max, nonce, 0);

        uint256 expectedFee = (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        uint256 sellerWethBefore = weth.balanceOf(seller);
        uint256 buyerWethBefore = weth.balanceOf(buyer);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, exp, type(uint256).max, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(weth.balanceOf(seller) - sellerWethBefore, offerAmount);
        assertEq(buyerWethBefore - weth.balanceOf(buyer), uint256(offerAmount) + expectedFee);
        assertEq(weth.balanceOf(address(marketplace)), expectedFee);
    }

    function test_acceptSignedOffer_revertsWhenFeeExceedsSignedMax() public {
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether); // revenue = 1 ether
        uint64 exp = uint64(block.timestamp + 1 days);

        // Buyer signs with maxOfferFee = 0.01 ether (less than actual fee of 0.08)
        uint256 lowMaxFee = 0.01 ether;
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, offerAmount, exp, lowMaxFee, nonce, 0);

        // Actual fee = 0.08 ether > 0.01 ether, so accept reverts
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.FeeExceedsMax.selector);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, exp, lowMaxFee, nonce, 0, sig);
    }

    function test_acceptSignedOffer_usesLowerFeeWhenAdminLowersCharges() public {
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether);
        uint64 exp = uint64(block.timestamp + 1 days);

        // Buyer signs with generous maxOfferFee
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, offerAmount, exp, type(uint256).max, nonce, 0);

        // Admin LOWERS fee before acceptance
        uint16 lowerBps = 100; // 1%
        uint16 listingBps = marketplace.sListingFeeBps();
        vm.prank(mpOwner);
        marketplace.setFeeBps(listingBps, lowerBps);

        uint256 expectedLowerFee = (uint256(1 ether) * uint256(lowerBps)) / 10000;

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, exp, type(uint256).max, nonce, 0, sig);

        assertEq(weth.balanceOf(address(marketplace)), expectedLowerFee);
    }

    function test_acceptSignedOffer_adminFeeTest_raisedBpsRevertsUnderSignedCap() public {
        // Admin has fee at 800 bps. Buyer signs with a cap big enough for 800 bps on a 1 ether
        // revenue (0.08 ether). Admin RAISES the offer fee to 9000 bps, which on the same revenue
        // is 0.9 ether and exceeds the signed cap, so accept reverts.
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether); // revenue = 1 ether
        uint64 exp = uint64(block.timestamp + 1 days);

        uint256 cap = 0.5 ether; // passes 800 bps, fails 9000 bps
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, offerAmount, exp, cap, nonce, 0);

        // Admin raises the offer fee bps so the computed fee exceeds the signed cap.
        uint16 listingBps = marketplace.sListingFeeBps();
        vm.prank(mpOwner);
        marketplace.setFeeBps(listingBps, 9000);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.FeeExceedsMax.selector);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, exp, cap, nonce, 0, sig);
    }

    // ───── Non-payable: acceptSignedOffer rejects ETH ─────

    function test_acceptSignedOffer_rejectsSentEth() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, 1 ether, exp, type(uint256).max, nonce, 0);

        vm.prank(seller);
        vm.deal(seller, 1 ether);
        (bool ok,) = address(marketplace).call{value: 1}(
            abi.encodeWithSelector(
                marketplace.acceptSignedOffer.selector,
                bondId,
                buyer,
                uint128(1 ether),
                exp,
                type(uint256).max,
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
        bytes memory sig = _signOffer(BUYER_PK, bondId, offerAmount, exp, type(uint256).max, nonce, 0);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, exp, type(uint256).max, nonce, 0, sig);

        uint256 expectedFee = (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        assertEq(weth.balanceOf(address(marketplace)), expectedFee);

        uint256 recipBefore = weth.balanceOf(feeRecipient);
        vm.prank(mpOwner);
        marketplace.claimWethFees();

        assertEq(weth.balanceOf(feeRecipient) - recipBefore, expectedFee);
        assertEq(weth.balanceOf(address(marketplace)), 0);
    }
}
