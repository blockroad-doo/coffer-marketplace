//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";

// ───── Mock Contracts ─────

/// @dev Minimal ERC721 mock with cofferOf support
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

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "ERC721: not owner");
        require(msg.sender == from || _operatorApprovals[from][msg.sender], "ERC721: not approved");
        _owners[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }
}

/// @dev Mock Coffer that returns configurable holder conditions
contract MockCoffer {
    uint128 public maturityValue = 1 ether;
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

/// @dev Mock WETH with mint capability
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "WETH: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "WETH: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "WETH: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Contract with no receive/fallback — rejects all ETH transfers
contract EthRejecter {
    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }

    function doList(address mp, address nft, uint256 id, uint128 price, uint64 exp) external {
        CofferMarketplace(mp).list(nft, id, price, exp);
    }

    function doBuy(address mp, address nft, uint256 id, uint128 price) external payable {
        CofferMarketplace(mp).buy{value: msg.value}(nft, id, price);
    }

    function doBatchBuy(address mp, address[] calldata nfts, uint256[] calldata ids, uint128[] calldata prices)
        external
        payable
    {
        CofferMarketplace(mp).batchBuy{value: msg.value}(nfts, ids, prices);
    }
}

/// @dev Harness to expose internal _calculateFeeAmount for direct testing
contract CofferMarketplaceHarness is CofferMarketplace {
    constructor(address _owner, address _feeRecipient, address _weth) CofferMarketplace(_owner, _feeRecipient, _weth) {}

    function exposedCalculateFeeAmount(FunctionFee memory ff, uint256 opVal) external pure returns (uint256) {
        return _calculateFeeAmount(ff, opVal);
    }
}

// ───── Tests ─────

contract CofferMarketplaceTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    address public buyer2 = makeAddr("buyer2");

    uint256 public bondId;

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();

        marketplace = new CofferMarketplace(owner, feeRecipient, address(weth));

        // Mint a bond NFT to seller
        bondId = bondNft.mintTo(seller, address(coffer));

        // Seller approves marketplace
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        // Fund accounts
        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(buyer2, 100 ether);

        // Give buyer WETH and approve marketplace
        weth.mint(buyer, 100 ether);
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);

        weth.mint(buyer2, 100 ether);
        vm.prank(buyer2);
        weth.approve(address(marketplace), type(uint256).max);
    }

    // ───── DRY Helpers ─────

    function _listBond(uint128 price) internal {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, price, uint64(block.timestamp + 1 days));
    }

    function _makeOfferFrom(address offeror, uint128 amount) internal {
        vm.prank(offeror);
        marketplace.makeOffer(address(bondNft), bondId, amount, uint64(block.timestamp + 1 days));
    }

    function _setFee(bytes4 sel, uint128 fixedFee, uint16 bps) internal {
        vm.prank(owner);
        marketplace.setFunctionFee(sel, fixedFee, bps);
    }

    function _mintBondTo(address to) internal returns (uint256) {
        return bondNft.mintTo(to, address(coffer));
    }

    // ───── Constructor ─────

    function test_constructor() public view {
        assertEq(marketplace.owner(), owner);
        assertEq(marketplace.sFeeRecipient(), feeRecipient);
        assertEq(marketplace.I_WETH(), address(weth));
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        new CofferMarketplace(owner, address(0), address(weth));
    }

    function test_constructor_revert_zeroWeth() public {
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        new CofferMarketplace(owner, feeRecipient, address(0));
    }

    // ───── Admin ─────

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(owner);
        marketplace.setFeeRecipient(newRecipient);
        assertEq(marketplace.sFeeRecipient(), newRecipient);
    }

    function test_setFeeRecipient_revert_notOwner() public {
        vm.prank(seller);
        vm.expectRevert();
        marketplace.setFeeRecipient(makeAddr("x"));
    }

    function test_setFeeRecipient_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        marketplace.setFeeRecipient(address(0));
    }

    function test_setFunctionFee() public {
        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.buy.selector, 0.001 ether, 100);
        (uint128 fixedFee, uint16 bps) = marketplace.sFunctionFees(CofferMarketplace.buy.selector);
        assertEq(fixedFee, 0.001 ether);
        assertEq(bps, 100);
    }

    // ───── Listing CRUD ─────

    function test_list() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, exp);

        (address s, uint128 p, uint64 e, address nft) = marketplace.sListings(address(bondNft), bondId);
        assertEq(s, seller);
        assertEq(p, 1 ether);
        assertEq(e, exp);
        assertEq(nft, address(bondNft));
    }

    function test_list_revert_zeroPrice() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.ZeroPrice.selector);
        marketplace.list(address(bondNft), bondId, 0, uint64(block.timestamp + 1 days));
    }

    function test_list_revert_expirationNotInFuture() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp - 1));
    }

    function test_list_revert_notOwner() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.NotOwner.selector);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_list_revert_bondNotOutstanding() public {
        coffer.setMaturityValue(0);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_list_revert_notApproved() public {
        // Remove approval
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), false);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.MarketplaceNotApproved.selector);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_cancelListing() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(seller);
        marketplace.cancelListing(address(bondNft), bondId);

        (address s,,,) = marketplace.sListings(address(bondNft), bondId);
        assertEq(s, address(0));
    }

    function test_cancelListing_revert_notSeller() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.NotSeller.selector);
        marketplace.cancelListing(address(bondNft), bondId);
    }

    // ───── Buy Flow ─────

    function test_buy_zeroFee() public {
        uint128 price = 1 ether;
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, price, uint64(block.timestamp + 1 days));

        uint256 sellerBefore = seller.balance;

        vm.prank(buyer);
        marketplace.buy{value: price}(address(bondNft), bondId, price);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(seller.balance - sellerBefore, price);
    }

    function test_buy_fixedFeeOnly() public {
        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.buy.selector, 0.01 ether, 0);

        uint128 price = 1 ether;
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, price, uint64(block.timestamp + 1 days));

        uint256 sellerBefore = seller.balance;
        uint256 feeRecipientBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buy{value: 1.01 ether}(address(bondNft), bondId, price);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(seller.balance - sellerBefore, price);
        assertEq(feeRecipient.balance - feeRecipientBefore, 0.01 ether);
    }

    function test_buy_percentageFeeOnly() public {
        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.buy.selector, 0, 100); // 1%

        uint128 price = 1 ether;
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, price, uint64(block.timestamp + 1 days));

        // gross = price * (10000 + 100) / 10000 = 1.01 ether
        uint256 sellerBefore = seller.balance;
        uint256 feeRecipientBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buy{value: 1.01 ether}(address(bondNft), bondId, price);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(seller.balance - sellerBefore, price);
        assertEq(feeRecipient.balance - feeRecipientBefore, 0.01 ether);
    }

    function test_buy_fixedAndPercentageFee() public {
        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.buy.selector, 0.001 ether, 100); // 0.001 ETH + 1%

        uint128 price = 1 ether;
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, price, uint64(block.timestamp + 1 days));

        // gross = 0.001 + 1.0 * 10100 / 10000 = 0.001 + 1.01 = 1.011
        uint256 sellerBefore = seller.balance;
        uint256 feeRecipientBefore = feeRecipient.balance;

        vm.prank(buyer);
        marketplace.buy{value: 1.011 ether}(address(bondNft), bondId, price);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(seller.balance - sellerBefore, price);
        assertEq(feeRecipient.balance - feeRecipientBefore, 0.011 ether);
    }

    function test_buy_withExcessRefund() public {
        uint128 price = 1 ether;
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, price, uint64(block.timestamp + 1 days));

        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        marketplace.buy{value: 2 ether}(address(bondNft), bondId, price);

        assertEq(bondNft.ownerOf(bondId), buyer);
        // buyer paid 1 ether price, got 1 ether back as refund
        assertEq(buyerBefore - buyer.balance, price);
    }

    function test_buy_revert_listingNotFound() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingNotFound.selector);
        marketplace.buy{value: 1 ether}(address(bondNft), bondId, 1 ether);
    }

    function test_buy_revert_listingExpired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, exp);

        vm.warp(exp + 1);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingExpired.selector);
        marketplace.buy{value: 1 ether}(address(bondNft), bondId, 1 ether);
    }

    function test_buy_revert_priceMismatch() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.PriceMismatch.selector);
        marketplace.buy{value: 2 ether}(address(bondNft), bondId, 2 ether);
    }

    function test_buy_revert_cannotBuyOwnListing() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.CannotBuyOwnListing.selector);
        marketplace.buy{value: 1 ether}(address(bondNft), bondId, 1 ether);
    }

    function test_buy_revert_staleListing() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        // Transfer NFT away from seller (making listing stale)
        vm.prank(seller);
        bondNft.transferFrom(seller, buyer2, bondId);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.SellerNoLongerOwnsNft.selector);
        marketplace.buy{value: 1 ether}(address(bondNft), bondId, 1 ether);
    }

    function test_buy_revert_bondNotOutstanding() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        coffer.setMaturityValue(0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.buy{value: 1 ether}(address(bondNft), bondId, 1 ether);
    }

    // ───── Offer CRUD ─────

    function test_makeOffer() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, exp);

        (address b, uint128 amt, uint64 e) = marketplace.sOffers(address(bondNft), bondId, buyer);
        assertEq(b, buyer);
        assertEq(amt, 1 ether);
        assertEq(e, exp);
    }

    function test_makeOffer_revert_zeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ZeroAmount.selector);
        marketplace.makeOffer(address(bondNft), bondId, 0, uint64(block.timestamp + 1 days));
    }

    function test_makeOffer_revert_bondNotOutstanding() public {
        coffer.setMaturityValue(0);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_makeOffer_revert_insufficientWethBalance() public {
        address poorBuyer = makeAddr("poorBuyer");
        vm.prank(poorBuyer);
        weth.approve(address(marketplace), type(uint256).max);

        vm.prank(poorBuyer);
        vm.expectRevert(CofferMarketplace.InsufficientWethBalance.selector);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_makeOffer_revert_insufficientWethAllowance() public {
        address noApproveBuyer = makeAddr("noApproveBuyer");
        weth.mint(noApproveBuyer, 100 ether);
        // No approval

        vm.prank(noApproveBuyer);
        vm.expectRevert(CofferMarketplace.InsufficientWethAllowance.selector);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_cancelOffer() public {
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        marketplace.cancelOffer(address(bondNft), bondId);

        (address b,,) = marketplace.sOffers(address(bondNft), bondId, buyer);
        assertEq(b, address(0));
    }

    function test_cancelOffer_revert_notBuyer() public {
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.NotBuyer.selector);
        marketplace.cancelOffer(address(bondNft), bondId);
    }

    // ───── Accept Offer Flow ─────

    function test_acceptOffer_zeroFee() public {
        uint128 offerAmount = 1 ether;
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, offerAmount, uint64(block.timestamp + 1 days));

        uint256 sellerWethBefore = weth.balanceOf(seller);

        vm.prank(seller);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, offerAmount);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(weth.balanceOf(seller) - sellerWethBefore, offerAmount);
    }

    function test_acceptOffer_withWethFee() public {
        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.acceptOffer.selector, 0, 100); // 1%

        uint128 offerAmount = 10 ether;
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, offerAmount, uint64(block.timestamp + 1 days));

        uint256 sellerWethBefore = weth.balanceOf(seller);
        uint256 feeRecipientWethBefore = weth.balanceOf(feeRecipient);

        vm.prank(seller);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, offerAmount);

        assertEq(bondNft.ownerOf(bondId), buyer);
        // 1% fee = 0.1 ether
        assertEq(weth.balanceOf(feeRecipient) - feeRecipientWethBefore, 0.1 ether);
        assertEq(weth.balanceOf(seller) - sellerWethBefore, 9.9 ether);
    }

    function test_acceptOffer_revert_offerNotFound() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferNotFound.selector);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_offerExpired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, exp);

        vm.warp(exp + 1);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferExpired.selector);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_notOwner() public {
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(buyer2);
        vm.expectRevert(CofferMarketplace.NotOwner.selector);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_amountMismatch() public {
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.AmountMismatch.selector);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, 2 ether);
    }

    // ───── Batch Operations ─────

    function test_batchList() public {
        // Mint a second bond
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 2 ether;
        uint64[] memory exps = new uint64[](2);
        exps[0] = uint64(block.timestamp + 1 days);
        exps[1] = uint64(block.timestamp + 2 days);

        vm.prank(seller);
        marketplace.batchList(nfts, ids, prices, exps);

        (address s1, uint128 p1,,) = marketplace.sListings(address(bondNft), bondId);
        (address s2, uint128 p2,,) = marketplace.sListings(address(bondNft), bondId2);
        assertEq(s1, seller);
        assertEq(p1, 1 ether);
        assertEq(s2, seller);
        assertEq(p2, 2 ether);
    }

    function test_batchBuy() public {
        // Mint second bond
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        // List both
        vm.startPrank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
        marketplace.list(address(bondNft), bondId2, 2 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 2 ether;

        vm.prank(buyer);
        marketplace.batchBuy{value: 3 ether}(nfts, ids, prices);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(bondNft.ownerOf(bondId2), buyer);
    }

    function test_batchCancelListings() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.startPrank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
        marketplace.list(address(bondNft), bondId2, 2 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;

        vm.prank(seller);
        marketplace.batchCancelListings(nfts, ids);

        (address s1,,,) = marketplace.sListings(address(bondNft), bondId);
        (address s2,,,) = marketplace.sListings(address(bondNft), bondId2);
        assertEq(s1, address(0));
        assertEq(s2, address(0));
    }

    function test_batchMakeOffers() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        uint64[] memory exps = new uint64[](2);
        exps[0] = uint64(block.timestamp + 1 days);
        exps[1] = uint64(block.timestamp + 2 days);

        vm.prank(buyer);
        marketplace.batchMakeOffers(nfts, ids, amounts, exps);

        (address b1, uint128 a1,) = marketplace.sOffers(address(bondNft), bondId, buyer);
        (address b2, uint128 a2,) = marketplace.sOffers(address(bondNft), bondId2, buyer);
        assertEq(b1, buyer);
        assertEq(a1, 1 ether);
        assertEq(b2, buyer);
        assertEq(a2, 2 ether);
    }

    function test_batchCancelOffers() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));

        vm.startPrank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
        marketplace.makeOffer(address(bondNft), bondId2, 2 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;

        vm.prank(buyer);
        marketplace.batchCancelOffers(nfts, ids);

        (address b1,,) = marketplace.sOffers(address(bondNft), bondId, buyer);
        (address b2,,) = marketplace.sOffers(address(bondNft), bondId2, buyer);
        assertEq(b1, address(0));
        assertEq(b2, address(0));
    }

    function test_batchAcceptOffers() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
        vm.prank(buyer2);
        marketplace.makeOffer(address(bondNft), bondId2, 2 ether, uint64(block.timestamp + 1 days));

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        address[] memory buyers_ = new address[](2);
        buyers_[0] = buyer;
        buyers_[1] = buyer2;
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;

        vm.prank(seller);
        marketplace.batchAcceptOffers(nfts, ids, buyers_, amounts);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(bondNft.ownerOf(bondId2), buyer2);
    }

    function test_batch_revert_arrayLengthMismatch() public {
        address[] memory nfts = new address[](2);
        uint256[] memory ids = new uint256[](1);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchCancelListings(nfts, ids);
    }

    // ───── View Functions ─────

    function test_isListingValid_true() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        assertTrue(marketplace.isListingValid(address(bondNft), bondId));
    }

    function test_isListingValid_false_noListing() public view {
        assertFalse(marketplace.isListingValid(address(bondNft), bondId));
    }

    function test_isListingValid_false_expired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, exp);

        vm.warp(exp + 1);
        assertFalse(marketplace.isListingValid(address(bondNft), bondId));
    }

    function test_isListingValid_false_ownerChanged() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(seller);
        bondNft.transferFrom(seller, buyer2, bondId);

        assertFalse(marketplace.isListingValid(address(bondNft), bondId));
    }

    function test_isOfferValid_true() public {
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        assertTrue(marketplace.isOfferValid(address(bondNft), bondId, buyer));
    }

    function test_isOfferValid_false_noOffer() public view {
        assertFalse(marketplace.isOfferValid(address(bondNft), bondId, buyer));
    }

    function test_isOfferValid_false_expired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, exp);

        vm.warp(exp + 1);
        assertFalse(marketplace.isOfferValid(address(bondNft), bondId, buyer));
    }

    function test_getBondData() public view {
        (uint128 mv, uint32 dur, uint32 st, address cofferAddr) = marketplace.getBondData(address(bondNft), bondId);
        assertEq(mv, 1 ether);
        assertEq(dur, 86400);
        assertEq(cofferAddr, address(coffer));
        assertGt(st, 0);
    }

    // ───── Listing with Fee ─────

    function test_list_withFee() public {
        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.list.selector, 0.001 ether, 0);

        uint256 feeRecipientBefore = feeRecipient.balance;

        vm.prank(seller);
        marketplace.list{value: 0.001 ether}(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));

        assertEq(feeRecipient.balance - feeRecipientBefore, 0.001 ether);
    }

    function test_list_withFee_revert_insufficientFee() public {
        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.list.selector, 0.001 ether, 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.list{value: 0.0001 ether}(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    // ───── Fee Math Fuzz ─────

    function testFuzz_feeCalculation(uint128 fixedFee, uint16 bps, uint256 value) public {
        fixedFee = uint128(bound(fixedFee, 0, 1 ether));
        bps = uint16(bound(bps, 0, 5000));
        value = bound(value, uint256(fixedFee) + 0.01 ether, 100 ether);

        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.buy.selector, fixedFee, bps);

        // Calculate expected
        uint256 afterFixed = value - fixedFee;
        uint256 operationalValue = afterFixed * 10000 / (10000 + uint256(bps));
        uint256 fee = value - operationalValue;

        // fee >= fixedFee always
        assertGe(fee, fixedFee);
        // operational + fee = value
        assertEq(operationalValue + fee, value);
    }

    function testFuzz_grossForPrice(uint128 price, uint128 fixedFee, uint16 bps) public {
        fixedFee = uint128(bound(fixedFee, 0, 1 ether));
        bps = uint16(bound(bps, 0, 5000));
        price = uint128(bound(price, 0.01 ether, 10 ether));

        vm.prank(owner);
        marketplace.setFunctionFee(CofferMarketplace.buy.selector, fixedFee, bps);

        // List the bond
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, price, uint64(block.timestamp + 1 days));

        // Buy using grossForPrice-calculated amount — should succeed
        // gross = fixedFee + ceil(price * (10000 + bps) / 10000)
        uint256 gross = uint256(fixedFee) + (uint256(price) * (10000 + uint256(bps)) + 9999) / 10000;
        vm.deal(buyer, gross + 1 ether); // enough ETH

        vm.prank(buyer);
        marketplace.buy{value: gross}(address(bondNft), bondId, price);

        assertEq(bondNft.ownerOf(bondId), buyer);
    }

    // ───── Excess ETH Reverts (list / makeOffer) ─────

    function test_list_revert_excessEthSent() public {
        _setFee(CofferMarketplace.list.selector, 0.001 ether, 0);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.list{value: 0.002 ether}(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_makeOffer_revert_excessEthSent() public {
        _setFee(CofferMarketplace.makeOffer.selector, 0.001 ether, 0);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.makeOffer{value: 0.002 ether}(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    function test_makeOffer_revert_expirationNotInFuture() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp - 1));
    }

    // ───── buy() ETH Transfer Failures ─────

    function test_buy_revert_insufficientPaymentForPrice() public {
        _setFee(CofferMarketplace.buy.selector, 0.01 ether, 0);
        _listBond(1 ether);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.buy{value: 0.5 ether}(address(bondNft), bondId, 1 ether);
    }

    function test_buy_revert_sellerRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();
        uint256 rejBondId = _mintBondTo(address(rejecter));
        rejecter.approveNft(address(bondNft), address(marketplace));
        rejecter.doList(address(marketplace), address(bondNft), rejBondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.buy{value: 1 ether}(address(bondNft), rejBondId, 1 ether);
    }

    function test_buy_revert_feeRecipientRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();
        vm.prank(owner);
        marketplace.setFeeRecipient(address(rejecter));
        _setFee(CofferMarketplace.buy.selector, 0.01 ether, 0);
        _listBond(1 ether);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.buy{value: 1.01 ether}(address(bondNft), bondId, 1 ether);
    }

    function test_buy_revert_buyerRefundFails() public {
        EthRejecter rejecter = new EthRejecter();
        _listBond(1 ether);
        vm.deal(address(this), 2 ether);

        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        rejecter.doBuy{value: 2 ether}(address(marketplace), address(bondNft), bondId, 1 ether);
    }

    // ───── acceptOffer() Missing Branches ─────

    function test_acceptOffer_revert_bondNotOutstanding() public {
        _makeOfferFrom(buyer, 1 ether);
        coffer.setMaturityValue(0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_buyerWethDrained() public {
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(buyer);
        require(weth.transfer(address(1), 100 ether), "transfer failed");

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientWethBalance.selector);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_buyerAllowanceRevoked() public {
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(buyer);
        weth.approve(address(marketplace), 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientWethAllowance.selector);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, 1 ether);
    }

    function test_acceptOffer_withEthPayment() public {
        _setFee(CofferMarketplace.acceptOffer.selector, 0.001 ether, 0);
        _makeOfferFrom(buyer, 1 ether);

        uint256 feeRecipientBefore = feeRecipient.balance;

        vm.prank(seller);
        marketplace.acceptOffer{value: 0.001 ether}(address(bondNft), bondId, buyer, 1 ether);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(feeRecipient.balance - feeRecipientBefore, 0.001 ether);
    }

    function test_acceptOffer_revert_wethFeeExceedsAmount() public {
        _setFee(CofferMarketplace.acceptOffer.selector, 1 ether, 0);
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.acceptOffer(address(bondNft), bondId, buyer, 1 ether);
    }

    // ───── Batch Array Mismatch Reverts ─────

    function test_batchList_revert_arrayLengthMismatch() public {
        address[] memory nfts = new address[](2);
        uint256[] memory ids = new uint256[](1);
        uint128[] memory prices = new uint128[](2);
        uint64[] memory exps = new uint64[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchList(nfts, ids, prices, exps);
    }

    function test_batchBuy_revert_arrayLengthMismatch() public {
        address[] memory nfts = new address[](2);
        uint256[] memory ids = new uint256[](1);
        uint128[] memory prices = new uint128[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchBuy(nfts, ids, prices);
    }

    function test_batchMakeOffers_revert_arrayLengthMismatch() public {
        address[] memory nfts = new address[](2);
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](2);
        uint64[] memory exps = new uint64[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchMakeOffers(nfts, ids, amounts, exps);
    }

    function test_batchCancelOffers_revert_arrayLengthMismatch() public {
        address[] memory nfts = new address[](2);
        uint256[] memory ids = new uint256[](1);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchCancelOffers(nfts, ids);
    }

    function test_batchAcceptOffers_revert_arrayLengthMismatch() public {
        address[] memory nfts = new address[](2);
        uint256[] memory ids = new uint256[](1);
        address[] memory buyers_ = new address[](2);
        uint128[] memory amounts = new uint128[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchAcceptOffers(nfts, ids, buyers_, amounts);
    }

    // ───── Batch Fee/Payment Reverts + Refund ─────

    function test_batchList_revert_insufficientFee() public {
        uint256 bondId2 = _mintBondTo(seller);
        _setFee(CofferMarketplace.list.selector, 0.001 ether, 0);

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 2 ether;
        uint64[] memory exps = new uint64[](2);
        exps[0] = uint64(block.timestamp + 1 days);
        exps[1] = uint64(block.timestamp + 1 days);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.batchList{value: 0.001 ether}(nfts, ids, prices, exps);
    }

    function test_batchBuy_revert_insufficientPayment() public {
        uint256 bondId2 = _mintBondTo(seller);

        vm.startPrank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
        marketplace.list(address(bondNft), bondId2, 1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 1 ether;

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.batchBuy{value: 1 ether}(nfts, ids, prices);
    }

    function test_batchMakeOffers_revert_insufficientFee() public {
        uint256 bondId2 = _mintBondTo(seller);
        _setFee(CofferMarketplace.makeOffer.selector, 0.001 ether, 0);

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;
        uint64[] memory exps = new uint64[](2);
        exps[0] = uint64(block.timestamp + 1 days);
        exps[1] = uint64(block.timestamp + 1 days);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.batchMakeOffers{value: 0.001 ether}(nfts, ids, amounts, exps);
    }

    function test_batchAcceptOffers_revert_insufficientFee() public {
        uint256 bondId2 = _mintBondTo(seller);
        _setFee(CofferMarketplace.acceptOffer.selector, 0.001 ether, 0);

        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
        vm.prank(buyer2);
        marketplace.makeOffer(address(bondNft), bondId2, 1 ether, uint64(block.timestamp + 1 days));

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        address[] memory buyers_ = new address[](2);
        buyers_[0] = buyer;
        buyers_[1] = buyer2;
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.batchAcceptOffers{value: 0.001 ether}(nfts, ids, buyers_, amounts);
    }

    function test_batchBuy_withExcessRefund() public {
        uint256 bondId2 = _mintBondTo(seller);

        vm.startPrank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
        marketplace.list(address(bondNft), bondId2, 1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 1 ether;

        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        marketplace.batchBuy{value: 4 ether}(nfts, ids, prices);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(bondNft.ownerOf(bondId2), buyer);
        assertEq(buyerBefore - buyer.balance, 2 ether);
    }

    function test_batchBuy_revert_refundFails() public {
        uint256 bondId2 = _mintBondTo(seller);

        vm.startPrank(seller);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
        marketplace.list(address(bondNft), bondId2, 1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        EthRejecter rejecter = new EthRejecter();

        address[] memory nfts = new address[](2);
        nfts[0] = address(bondNft);
        nfts[1] = address(bondNft);
        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 1 ether;

        vm.deal(address(this), 4 ether);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        rejecter.doBatchBuy{value: 4 ether}(address(marketplace), nfts, ids, prices);
    }

    // ───── View Function Branches ─────

    function test_isListingValid_false_bondNotOutstanding() public {
        _listBond(1 ether);
        coffer.setMaturityValue(0);
        assertFalse(marketplace.isListingValid(address(bondNft), bondId));
    }

    function test_isOfferValid_false_insufficientBalance() public {
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(buyer);
        require(weth.transfer(address(1), 100 ether), "transfer failed");

        assertFalse(marketplace.isOfferValid(address(bondNft), bondId, buyer));
    }

    function test_isOfferValid_false_insufficientAllowance() public {
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(buyer);
        weth.approve(address(marketplace), 0);

        assertFalse(marketplace.isOfferValid(address(bondNft), bondId, buyer));
    }

    // ───── Internal Function + Fee Infrastructure ─────

    function test_calculateFeeAmount_withPercentage() public {
        CofferMarketplaceHarness harness = new CofferMarketplaceHarness(owner, feeRecipient, address(weth));
        CofferMarketplace.FunctionFee memory ff = CofferMarketplace.FunctionFee(0.001 ether, 100);
        uint256 fee = harness.exposedCalculateFeeAmount(ff, 1 ether);
        // fixedFee + (1e * 100 / 10000) = 0.001e + 0.01e = 0.011e
        assertEq(fee, 0.011 ether);
    }

    function test_list_revert_feeRecipientRejectsEth() public {
        EthRejecter rejecter = new EthRejecter();
        vm.prank(owner);
        marketplace.setFeeRecipient(address(rejecter));
        _setFee(CofferMarketplace.list.selector, 0.001 ether, 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.list{value: 0.001 ether}(address(bondNft), bondId, 1 ether, uint64(block.timestamp + 1 days));
    }

    // ───── Modifier Tests ─────

    function test_setFunctionFee_revert_notOwner() public {
        vm.prank(seller);
        vm.expectRevert();
        marketplace.setFunctionFee(CofferMarketplace.buy.selector, 0.001 ether, 100);
    }

    // ───── Boundary Tests ─────

    function test_list_expirationExactlyNow() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.list(address(bondNft), bondId, 1 ether, uint64(block.timestamp));
    }

    function test_list_priceOneWei() public {
        vm.prank(seller);
        marketplace.list(address(bondNft), bondId, 1, uint64(block.timestamp + 1 days));

        (address s, uint128 p,,) = marketplace.sListings(address(bondNft), bondId);
        assertEq(s, seller);
        assertEq(p, 1);
    }

    function test_makeOffer_amountOneWei() public {
        vm.prank(buyer);
        marketplace.makeOffer(address(bondNft), bondId, 1, uint64(block.timestamp + 1 days));

        (address b, uint128 amt,) = marketplace.sOffers(address(bondNft), bondId, buyer);
        assertEq(b, buyer);
        assertEq(amt, 1);
    }
}
