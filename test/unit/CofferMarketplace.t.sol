//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";

// ───── Mock Contracts ─────

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

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

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
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

/// @dev Contract that accepts NFTs but rejects all ETH transfers
contract EthRejecter is IERC721Receiver {
    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }

    function doList(address mp, uint256 id, uint128 price, uint64 exp) external {
        CofferMarketplace(payable(mp)).list(id, price, exp, 0);
    }

    function doBuy(address mp, uint256 id, uint128 price) external payable {
        CofferMarketplace(payable(mp)).buy{value: msg.value}(id, price, 0);
    }

    function doBatchBuy(address mp, uint256[] calldata ids, uint128[] calldata prices) external payable {
        uint256[] memory maxFees = new uint256[](ids.length);
        CofferMarketplace(payable(mp)).batchBuy{value: msg.value}(ids, prices, maxFees);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

// ───── Tests ─────

contract CofferMarketplaceTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    address public buyer2 = makeAddr("buyer2");
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public bondId;

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();

        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

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
        marketplace.list(bondId, price, uint64(block.timestamp + 1 days), 0);
    }

    function _makeOfferFrom(address offeror, uint128 amount) internal {
        vm.prank(offeror);
        marketplace.makeOffer(bondId, amount, uint64(block.timestamp + 1 days), 0);
    }

    function _mintBondTo(address to) internal returns (uint256) {
        return bondNft.mintTo(to, address(coffer));
    }

    function _zeroMaxFees(uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
    }

    // ───── Constructor ─────

    function test_constructor() public view {
        assertEq(marketplace.I_WETH(), address(weth));
        assertEq(marketplace.I_COFFER_BOND_NFT(), address(bondNft));
        assertEq(marketplace.owner(), mpOwner);
        assertEq(marketplace.sFeeRecipient(), feeRecipient);
    }

    function test_constructor_revert_zeroWeth() public {
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        new CofferMarketplace(address(0), address(bondNft), mpOwner, feeRecipient);
    }

    function test_constructor_revert_zeroBondNft() public {
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        new CofferMarketplace(address(weth), address(0), mpOwner, feeRecipient);
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        new CofferMarketplace(address(weth), address(bondNft), mpOwner, address(0));
    }

    // ───── Listing CRUD ─────

    function test_list() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, exp, 0);

        (address s, uint128 p, uint64 e) = marketplace.sListings(bondId);
        assertEq(s, seller);
        assertEq(p, 1 ether);
        assertEq(e, exp);
    }

    function test_list_revert_zeroPrice() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.ZeroPrice.selector);
        marketplace.list(bondId, 0, uint64(block.timestamp + 1 days), 0);
    }

    function test_list_revert_expirationNotInFuture() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp - 1), 0);
    }

    function test_list_revert_notOwner() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.NotOwner.selector);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
    }

    function test_list_revert_bondNotOutstanding() public {
        coffer.setMaturityValue(0);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
    }

    function test_list_revert_notApproved() public {
        // Remove approval
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), false);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.MarketplaceNotApproved.selector);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
    }

    function test_list_emitsListingCancelledOnStaleOverwrite() public {
        // Seller lists bond
        _listBond(1 ether);

        // Seller transfers bond outside marketplace
        vm.prank(seller);
        bondNft.transferFrom(seller, buyer2, bondId);

        // New owner approves and re-lists — should emit ListingCancelled for old seller
        vm.prank(buyer2);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.expectEmit(true, true, false, false);
        emit CofferMarketplace.ListingCancelled(bondId, seller);

        vm.prank(buyer2);
        marketplace.list(bondId, 2 ether, uint64(block.timestamp + 1 days), 0);

        // New listing belongs to buyer2
        (address s, uint128 p,) = marketplace.sListings(bondId);
        assertEq(s, buyer2);
        assertEq(p, 2 ether);
    }

    function test_cancelListing() public {
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(seller);
        marketplace.cancelListing(bondId, 0);

        (address s,,) = marketplace.sListings(bondId);
        assertEq(s, address(0));
    }

    function test_cancelListing_revert_notSeller() public {
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.NotSeller.selector);
        marketplace.cancelListing(bondId, 0);
    }

    // ───── Buy Flow ─────

    function test_buy() public {
        uint128 price = 1 ether;
        vm.prank(seller);
        marketplace.list(bondId, price, uint64(block.timestamp + 1 days), 0);

        uint256 sellerBefore = seller.balance;

        vm.prank(buyer);
        marketplace.buy{value: price}(bondId, price, 0);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(seller.balance - sellerBefore, price);
    }

    function test_buy_withExcessRefund() public {
        uint128 price = 1 ether;
        vm.prank(seller);
        marketplace.list(bondId, price, uint64(block.timestamp + 1 days), 0);

        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        marketplace.buy{value: 2 ether}(bondId, price, 0);

        assertEq(bondNft.ownerOf(bondId), buyer);
        // buyer paid 1 ether price, got 1 ether back as refund
        assertEq(buyerBefore - buyer.balance, price);
    }

    function test_buy_revert_listingNotFound() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingNotFound.selector);
        marketplace.buy{value: 1 ether}(bondId, 1 ether, 0);
    }

    function test_buy_revert_listingExpired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, exp, 0);

        vm.warp(exp + 1);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingExpired.selector);
        marketplace.buy{value: 1 ether}(bondId, 1 ether, 0);
    }

    function test_buy_revert_priceMismatch() public {
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.PriceMismatch.selector);
        marketplace.buy{value: 2 ether}(bondId, 2 ether, 0);
    }

    function test_buy_revert_cannotBuyOwnListing() public {
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.CannotBuyOwnListing.selector);
        marketplace.buy{value: 1 ether}(bondId, 1 ether, 0);
    }

    function test_buy_revert_staleListing() public {
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        // Transfer NFT away from seller (making listing stale)
        vm.prank(seller);
        bondNft.transferFrom(seller, buyer2, bondId);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.SellerNoLongerOwnsNft.selector);
        marketplace.buy{value: 1 ether}(bondId, 1 ether, 0);
    }

    function test_buy_revert_bondNotOutstanding() public {
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        coffer.setMaturityValue(0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.buy{value: 1 ether}(bondId, 1 ether, 0);
    }

    function test_buy_revert_insufficientPayment() public {
        _listBond(1 ether);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.buy{value: 0.5 ether}(bondId, 1 ether, 0);
    }

    function test_buy_sellerRejectsEth_fallsBackToWeth() public {
        EthRejecter rejecter = new EthRejecter();
        uint256 rejBondId = _mintBondTo(address(rejecter));
        rejecter.approveNft(address(bondNft), address(marketplace));
        rejecter.doList(address(marketplace), rejBondId, 1 ether, uint64(block.timestamp + 1 days));

        vm.prank(buyer);
        marketplace.buy{value: 1 ether}(rejBondId, 1 ether, 0);

        // NFT transferred to buyer
        assertEq(bondNft.ownerOf(rejBondId), buyer);
        // Seller received WETH instead of ETH
        assertEq(weth.balanceOf(address(rejecter)), 1 ether);
        // Listing deleted
        (address s,,) = marketplace.sListings(rejBondId);
        assertEq(s, address(0));
    }

    function test_buy_revert_buyerRefundFails() public {
        EthRejecter rejecter = new EthRejecter();
        _listBond(1 ether);
        vm.deal(address(this), 2 ether);

        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        rejecter.doBuy{value: 2 ether}(address(marketplace), bondId, 1 ether);
    }

    // ───── Offer CRUD ─────

    function test_makeOffer() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, exp, 0);

        (address b, uint64 e, uint128 amt, uint128 f) = marketplace.sOffers(bondId, buyer);
        assertEq(b, buyer);
        assertEq(amt, 1 ether);
        assertEq(e, exp);
        assertEq(f, 0);
    }

    function test_makeOffer_revert_zeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ZeroAmount.selector);
        marketplace.makeOffer(bondId, 0, uint64(block.timestamp + 1 days), 0);
    }

    function test_makeOffer_revert_bondNotOutstanding() public {
        coffer.setMaturityValue(0);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
    }

    function test_makeOffer_revert_insufficientWethBalance() public {
        address poorBuyer = makeAddr("poorBuyer");
        vm.prank(poorBuyer);
        weth.approve(address(marketplace), type(uint256).max);

        vm.prank(poorBuyer);
        vm.expectRevert(CofferMarketplace.InsufficientWethBalance.selector);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
    }

    function test_makeOffer_revert_insufficientWethAllowance() public {
        address noApproveBuyer = makeAddr("noApproveBuyer");
        weth.mint(noApproveBuyer, 100 ether);
        // No approval

        vm.prank(noApproveBuyer);
        vm.expectRevert(CofferMarketplace.InsufficientWethAllowance.selector);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
    }

    function test_makeOffer_revert_expirationNotInFuture() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp - 1), 0);
    }

    function test_cancelOffer() public {
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(buyer);
        marketplace.cancelOffer(bondId, 0);

        (address b,,,) = marketplace.sOffers(bondId, buyer);
        assertEq(b, address(0));
    }

    function test_cancelOffer_revert_notBuyer() public {
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.NotBuyer.selector);
        marketplace.cancelOffer(bondId, 0);
    }

    // ───── Accept Offer Flow ─────

    function test_acceptOffer() public {
        uint128 offerAmount = 1 ether;
        vm.prank(buyer);
        marketplace.makeOffer(bondId, offerAmount, uint64(block.timestamp + 1 days), 0);

        uint256 sellerWethBefore = weth.balanceOf(seller);

        vm.prank(seller);
        marketplace.acceptOffer(bondId, buyer, offerAmount);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(weth.balanceOf(seller) - sellerWethBefore, offerAmount);
    }

    function test_acceptOffer_revert_offerNotFound() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferNotFound.selector);
        marketplace.acceptOffer(bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_offerExpired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, exp, 0);

        vm.warp(exp + 1);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferExpired.selector);
        marketplace.acceptOffer(bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_notOwner() public {
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(buyer2);
        vm.expectRevert(CofferMarketplace.NotOwner.selector);
        marketplace.acceptOffer(bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_cannotBuyOwnListing() public {
        // Seller makes offer on own bond
        weth.mint(seller, 10 ether);
        vm.prank(seller);
        weth.approve(address(marketplace), type(uint256).max);
        vm.prank(seller);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        // Seller tries to accept own offer
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.CannotBuyOwnListing.selector);
        marketplace.acceptOffer(bondId, seller, 1 ether);
    }

    function test_acceptOffer_revert_notApproved() public {
        // Create a new seller without marketplace approval
        address seller2 = makeAddr("seller2");
        uint256 bondId2 = bondNft.mintTo(seller2, address(coffer));

        // Buyer makes offer on seller2's bond
        vm.prank(buyer);
        marketplace.makeOffer(bondId2, 1 ether, uint64(block.timestamp + 1 days), 0);

        // Seller2 tries to accept without approving marketplace
        vm.prank(seller2);
        vm.expectRevert(CofferMarketplace.MarketplaceNotApproved.selector);
        marketplace.acceptOffer(bondId2, buyer, 1 ether);
    }

    function test_acceptOffer_revert_amountMismatch() public {
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.AmountMismatch.selector);
        marketplace.acceptOffer(bondId, buyer, 2 ether);
    }

    function test_acceptOffer_revert_bondNotOutstanding() public {
        _makeOfferFrom(buyer, 1 ether);
        coffer.setMaturityValue(0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.acceptOffer(bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_buyerWethDrained() public {
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(buyer);
        require(weth.transfer(address(1), 100 ether), "transfer failed");

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientWethBalance.selector);
        marketplace.acceptOffer(bondId, buyer, 1 ether);
    }

    function test_acceptOffer_revert_buyerAllowanceRevoked() public {
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(buyer);
        weth.approve(address(marketplace), 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientWethAllowance.selector);
        marketplace.acceptOffer(bondId, buyer, 1 ether);
    }

    // ───── Batch Operations ─────

    function test_batchList() public {
        // Mint a second bond
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

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
        marketplace.batchList(ids, prices, exps, _zeroMaxFees(2));

        (address s1, uint128 p1,) = marketplace.sListings(bondId);
        (address s2, uint128 p2,) = marketplace.sListings(bondId2);
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
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
        marketplace.list(bondId2, 2 ether, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 2 ether;

        vm.prank(buyer);
        marketplace.batchBuy{value: 3 ether}(ids, prices, _zeroMaxFees(2));

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(bondNft.ownerOf(bondId2), buyer);
    }

    function test_batchCancelListings() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.startPrank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
        marketplace.list(bondId2, 2 ether, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;

        vm.prank(seller);
        marketplace.batchCancelListings(ids, _zeroMaxFees(2));

        (address s1,,) = marketplace.sListings(bondId);
        (address s2,,) = marketplace.sListings(bondId2);
        assertEq(s1, address(0));
        assertEq(s2, address(0));
    }

    function test_batchMakeOffers() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));

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
        marketplace.batchMakeOffers(ids, amounts, exps, _zeroMaxFees(2));

        (address b1, , uint128 a1,) = marketplace.sOffers(bondId, buyer);
        (address b2, , uint128 a2,) = marketplace.sOffers(bondId2, buyer);
        assertEq(b1, buyer);
        assertEq(a1, 1 ether);
        assertEq(b2, buyer);
        assertEq(a2, 2 ether);
    }

    function test_batchCancelOffers() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));

        vm.startPrank(buyer);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
        marketplace.makeOffer(bondId2, 2 ether, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;

        vm.prank(buyer);
        marketplace.batchCancelOffers(ids, _zeroMaxFees(2));

        (address b1,,,) = marketplace.sOffers(bondId, buyer);
        (address b2,,,) = marketplace.sOffers(bondId2, buyer);
        assertEq(b1, address(0));
        assertEq(b2, address(0));
    }

    function test_batchAcceptOffers() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));
        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
        vm.prank(buyer2);
        marketplace.makeOffer(bondId2, 2 ether, uint64(block.timestamp + 1 days), 0);

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
        marketplace.batchAcceptOffers(ids, buyers_, amounts);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(bondNft.ownerOf(bondId2), buyer2);
    }

    // ───── Batch Reverts ─────

    function test_batchList_revert_arrayLengthMismatch() public {
        uint256[] memory ids = new uint256[](1);
        uint128[] memory prices = new uint128[](2);
        uint64[] memory exps = new uint64[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchList(ids, prices, exps, _zeroMaxFees(2));
    }

    function test_batchBuy_revert_arrayLengthMismatch() public {
        uint256[] memory ids = new uint256[](1);
        uint128[] memory prices = new uint128[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchBuy(ids, prices, _zeroMaxFees(2));
    }

    function test_batchMakeOffers_revert_arrayLengthMismatch() public {
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](2);
        uint64[] memory exps = new uint64[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchMakeOffers(ids, amounts, exps, _zeroMaxFees(2));
    }

    function test_batchAcceptOffers_revert_arrayLengthMismatch() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory buyers_ = new address[](2);
        uint128[] memory amounts = new uint128[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchAcceptOffers(ids, buyers_, amounts);
    }

    function test_batchCancelListings_revert_arrayLengthMismatch() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory maxFees = new uint256[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchCancelListings(ids, maxFees);
    }

    function test_batchCancelOffers_revert_arrayLengthMismatch() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory maxFees = new uint256[](2);

        vm.expectRevert(CofferMarketplace.ArrayLengthMismatch.selector);
        marketplace.batchCancelOffers(ids, maxFees);
    }

    function test_batchBuy_revert_insufficientPayment() public {
        uint256 bondId2 = _mintBondTo(seller);

        vm.startPrank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
        marketplace.list(bondId2, 1 ether, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 1 ether;

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.batchBuy{value: 1 ether}(ids, prices, _zeroMaxFees(2));
    }

    function test_batchBuy_withExcessRefund() public {
        uint256 bondId2 = _mintBondTo(seller);

        vm.startPrank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
        marketplace.list(bondId2, 1 ether, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 1 ether;

        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        marketplace.batchBuy{value: 4 ether}(ids, prices, _zeroMaxFees(2));

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(bondNft.ownerOf(bondId2), buyer);
        assertEq(buyerBefore - buyer.balance, 2 ether);
    }

    function test_batchBuy_revert_refundFails() public {
        uint256 bondId2 = _mintBondTo(seller);

        vm.startPrank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);
        marketplace.list(bondId2, 1 ether, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();

        EthRejecter rejecter = new EthRejecter();

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 1 ether;

        vm.deal(address(this), 4 ether);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        rejecter.doBatchBuy{value: 4 ether}(address(marketplace), ids, prices);
    }

    // ───── View Functions ─────

    function test_isListingValid_true() public {
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        assertTrue(marketplace.isListingValid(bondId));
    }

    function test_isListingValid_false_noListing() public view {
        assertFalse(marketplace.isListingValid(bondId));
    }

    function test_isListingValid_false_expired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, exp, 0);

        vm.warp(exp + 1);
        assertFalse(marketplace.isListingValid(bondId));
    }

    function test_isListingValid_false_ownerChanged() public {
        vm.prank(seller);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        vm.prank(seller);
        bondNft.transferFrom(seller, buyer2, bondId);

        assertFalse(marketplace.isListingValid(bondId));
    }

    function test_isListingValid_false_bondNotOutstanding() public {
        _listBond(1 ether);
        coffer.setMaturityValue(0);
        assertFalse(marketplace.isListingValid(bondId));
    }

    function test_isOfferValid_true() public {
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, uint64(block.timestamp + 1 days), 0);

        assertTrue(marketplace.isOfferValid(bondId, buyer));
    }

    function test_isOfferValid_false_noOffer() public view {
        assertFalse(marketplace.isOfferValid(bondId, buyer));
    }

    function test_isOfferValid_false_expired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1 ether, exp, 0);

        vm.warp(exp + 1);
        assertFalse(marketplace.isOfferValid(bondId, buyer));
    }

    function test_isOfferValid_false_insufficientBalance() public {
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(buyer);
        require(weth.transfer(address(1), 100 ether), "transfer failed");

        assertFalse(marketplace.isOfferValid(bondId, buyer));
    }

    function test_isOfferValid_false_insufficientAllowance() public {
        _makeOfferFrom(buyer, 1 ether);

        vm.prank(buyer);
        weth.approve(address(marketplace), 0);

        assertFalse(marketplace.isOfferValid(bondId, buyer));
    }

    function test_getBondData() public view {
        (uint128 mv, uint32 dur, uint32 st, address cofferAddr) = marketplace.getBondData(bondId);
        assertEq(mv, 1 ether);
        assertEq(dur, 86400);
        assertEq(cofferAddr, address(coffer));
        assertGt(st, 0);
    }

    // ───── Boundary Tests ─────

    function test_list_expirationExactlyNow() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.list(bondId, 1 ether, uint64(block.timestamp), 0);
    }

    function test_list_priceOneWei() public {
        vm.prank(seller);
        marketplace.list(bondId, 1, uint64(block.timestamp + 1 days), 0);

        (address s, uint128 p,) = marketplace.sListings(bondId);
        assertEq(s, seller);
        assertEq(p, 1);
    }

    function test_makeOffer_amountOneWei() public {
        vm.prank(buyer);
        marketplace.makeOffer(bondId, 1, uint64(block.timestamp + 1 days), 0);

        (address b, , uint128 amt,) = marketplace.sOffers(bondId, buyer);
        assertEq(b, buyer);
        assertEq(amt, 1);
    }
}
