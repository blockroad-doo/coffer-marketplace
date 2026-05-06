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

    address public seller = makeAddr("seller");
    address public buyer = makeAddr("buyer");
    address public nonOwner = makeAddr("nonOwner");
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public bondId;

    uint128 constant FLAT_FEE = 0.00005 ether;
    uint128 constant PROFIT_FIXED = 0.00005 ether;
    uint16 constant PROFIT_BPS = 800; // 8%

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();

        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

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
        vm.startPrank(mpOwner);
        marketplace.setFunctionFee(marketplace.list.selector, FLAT_FEE, 0);
        marketplace.setFunctionFee(marketplace.cancelListing.selector, FLAT_FEE, 0);
        marketplace.setFunctionFee(marketplace.makeOffer.selector, FLAT_FEE, 0);
        marketplace.setFunctionFee(marketplace.cancelOffer.selector, FLAT_FEE, 0);
        marketplace.setFunctionFee(marketplace.buy.selector, PROFIT_FIXED, PROFIT_BPS);
        marketplace.setFunctionFee(marketplace.acceptOffer.selector, PROFIT_FIXED, PROFIT_BPS);
        vm.stopPrank();
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

    // ───── Admin: setFunctionFee ─────

    function test_setFunctionFee() public {
        bytes4 sel = marketplace.list.selector;
        vm.prank(mpOwner);
        marketplace.setFunctionFee(sel, 123, 456);
        (uint128 fx, uint16 bps) = marketplace.sFunctionFees(sel);
        assertEq(fx, 123);
        assertEq(bps, 456);
    }

    function test_setFunctionFee_revert_notOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        marketplace.setFunctionFee(marketplace.list.selector, 1, 1);
    }

    function test_setFunctionFee_revert_bpsTooHigh() public {
        vm.prank(mpOwner);
        vm.expectRevert(CofferMarketplace.FeeTooHigh.selector);
        marketplace.setFunctionFee(marketplace.list.selector, 1, 10000);
    }

    // ───── Admin: Ownable2Step transfer ─────

    function test_ownable2Step_transfer() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(mpOwner);
        marketplace.transferOwnership(newOwner);

        // Old owner still controls until accept
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

    function test_claimFees_afterListFee() public {
        vm.prank(seller);
        marketplace.list{value: FLAT_FEE}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);

        assertEq(address(marketplace).balance, FLAT_FEE);

        uint256 recipBefore = feeRecipient.balance;
        vm.prank(mpOwner);
        marketplace.claimFees();
        assertEq(feeRecipient.balance - recipBefore, FLAT_FEE);
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

    // ───── Fee math: _list (flat) ─────

    function test_list_chargesFlatFee() public {
        uint256 mktBefore = address(marketplace).balance;
        vm.prank(seller);
        marketplace.list{value: FLAT_FEE}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);
        assertEq(address(marketplace).balance - mktBefore, FLAT_FEE);
    }

    function test_list_revert_insufficientFee_underpay() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.list{value: FLAT_FEE - 1}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);
    }

    function test_list_revert_insufficientFee_overpay() public {
        // Exact-match required
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.list{value: FLAT_FEE + 1}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);
    }

    function test_list_revert_feeExceedsMax() public {
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.FeeExceedsMax.selector);
        marketplace.list{value: FLAT_FEE}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE - 1);
    }

    // ───── Fee math: _buy (profit-based) ─────

    function test_buy_chargesProfitFee() public {
        uint128 price = 1 ether;
        coffer.setMaturityValue(2 ether); // profit = 1 ether

        // Seller lists (pays flat fee)
        vm.prank(seller);
        marketplace.list{value: FLAT_FEE}(bondId, price, uint64(block.timestamp + 1 days), FLAT_FEE);

        // Fee = PROFIT_FIXED + 1 ether * 800 / 10000 = 0.00005 + 0.08 = 0.08005 ether
        uint256 expectedBuyFee = uint256(PROFIT_FIXED) + (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        uint256 sellerBefore = seller.balance;
        uint256 buyerBefore = buyer.balance;
        uint256 mktBefore = address(marketplace).balance;

        vm.prank(buyer);
        marketplace.buy{value: price + expectedBuyFee}(bondId, price, expectedBuyFee);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(seller.balance - sellerBefore, price);
        assertEq(address(marketplace).balance - mktBefore, expectedBuyFee);
        assertEq(buyerBefore - buyer.balance, price + expectedBuyFee);
    }

    function test_buy_noProfit_stillChargesFixed() public {
        uint128 price = 10 ether; // >= maturityValue
        coffer.setMaturityValue(5 ether); // profit = 0 (price > maturity)
        weth.mint(seller, 100 ether); // allow WETH fallback if needed
        vm.deal(buyer, 100 ether);

        vm.prank(seller);
        marketplace.list{value: FLAT_FEE}(bondId, price, uint64(block.timestamp + 1 days), FLAT_FEE);

        uint256 expectedBuyFee = PROFIT_FIXED; // no profit → flat only
        vm.prank(buyer);
        marketplace.buy{value: uint256(price) + expectedBuyFee}(bondId, price, expectedBuyFee);
        assertEq(address(marketplace).balance, uint256(FLAT_FEE) + expectedBuyFee);
    }

    function test_buy_revert_feeExceedsMax() public {
        uint128 price = 1 ether;
        coffer.setMaturityValue(2 ether);

        vm.prank(seller);
        marketplace.list{value: FLAT_FEE}(bondId, price, uint64(block.timestamp + 1 days), FLAT_FEE);

        uint256 trueFee = uint256(PROFIT_FIXED) + (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.FeeExceedsMax.selector);
        marketplace.buy{value: price + trueFee}(bondId, price, trueFee - 1);
    }

    function test_buy_revert_insufficientPaymentForFee() public {
        uint128 price = 1 ether;
        coffer.setMaturityValue(2 ether);

        vm.prank(seller);
        marketplace.list{value: FLAT_FEE}(bondId, price, uint64(block.timestamp + 1 days), FLAT_FEE);

        uint256 trueFee = uint256(PROFIT_FIXED) + (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        // Send only price — missing fee
        marketplace.buy{value: price}(bondId, price, trueFee);
    }

    // ───── Fee lock at makeOffer ─────

    function test_makeOffer_locksFeeOnOffer() public {
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether); // revenue = 1 ether

        uint256 expectedLocked = uint256(PROFIT_FIXED) + (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;

        vm.prank(buyer);
        marketplace.makeOffer{value: FLAT_FEE}(bondId, offerAmount, uint64(block.timestamp + 1 days), FLAT_FEE);

        (,,, uint128 locked) = marketplace.sOffers(bondId, buyer);
        assertEq(locked, expectedLocked);
        assertEq(address(marketplace).balance, FLAT_FEE);
    }

    function test_acceptOffer_pullsLockedWethFee() public {
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether);

        vm.prank(buyer);
        marketplace.makeOffer{value: FLAT_FEE}(bondId, offerAmount, uint64(block.timestamp + 1 days), FLAT_FEE);

        uint256 expectedLocked = uint256(PROFIT_FIXED) + (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;

        uint256 sellerWethBefore = weth.balanceOf(seller);
        uint256 buyerWethBefore = weth.balanceOf(buyer);

        vm.prank(seller);
        marketplace.acceptOffer(bondId, buyer, offerAmount);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(weth.balanceOf(seller) - sellerWethBefore, offerAmount);
        assertEq(buyerWethBefore - weth.balanceOf(buyer), uint256(offerAmount) + expectedLocked);
        assertEq(weth.balanceOf(address(marketplace)), expectedLocked);
    }

    function test_acceptOffer_usesLockedFee_notCurrentConfig() public {
        // makeOffer at rate A
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether);
        vm.prank(buyer);
        marketplace.makeOffer{value: FLAT_FEE}(bondId, offerAmount, uint64(block.timestamp + 1 days), FLAT_FEE);

        uint256 expectedLocked = uint256(PROFIT_FIXED) + (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;

        // Admin changes acceptOffer fee to something much higher BEFORE acceptance
        vm.prank(mpOwner);
        marketplace.setFunctionFee(marketplace.acceptOffer.selector, 1 ether, 9000);

        // Accept uses the old locked fee, not the new config
        vm.prank(seller);
        marketplace.acceptOffer(bondId, buyer, offerAmount);

        assertEq(weth.balanceOf(address(marketplace)), expectedLocked);
    }

    function test_makeOffer_revert_insufficientWethForLockedFee() public {
        // Drain buyer to barely cover offer amount but not offer + fee
        uint128 offerAmount = 99 ether; // balance is 100, not enough for 99 + fee
        coffer.setMaturityValue(200 ether); // huge profit → big fee

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientWethBalance.selector);
        marketplace.makeOffer{value: FLAT_FEE}(bondId, offerAmount, uint64(block.timestamp + 1 days), FLAT_FEE);
    }

    // ───── Batch fee scaling ─────

    function test_batchList_chargesPerItemFee() public {
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
        exps[1] = uint64(block.timestamp + 1 days);
        uint256[] memory maxFees = new uint256[](2);
        maxFees[0] = FLAT_FEE;
        maxFees[1] = FLAT_FEE;

        vm.prank(seller);
        marketplace.batchList{value: uint256(FLAT_FEE) * 2}(ids, prices, exps, maxFees);

        assertEq(address(marketplace).balance, uint256(FLAT_FEE) * 2);
    }

    function test_batchList_revert_wrongTotalFee() public {
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
        exps[1] = uint64(block.timestamp + 1 days);
        uint256[] memory maxFees = new uint256[](2);
        maxFees[0] = FLAT_FEE;
        maxFees[1] = FLAT_FEE;

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        // only pay 1 item's worth of fee
        marketplace.batchList{value: FLAT_FEE}(ids, prices, exps, maxFees);
    }

    // ───── Non-payable: acceptOffer rejects ETH ─────

    function test_acceptOffer_rejectsSentEth() public {
        vm.prank(buyer);
        marketplace.makeOffer{value: FLAT_FEE}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);

        vm.prank(seller);
        vm.deal(seller, 1 ether);
        (bool ok,) = address(marketplace).call{value: 1}(
            abi.encodeWithSelector(marketplace.acceptOffer.selector, bondId, buyer, uint128(1 ether))
        );
        assertFalse(ok);
    }

    // ───── Claim: WETH happy path ─────

    function test_claimWethFees_afterAcceptOfferFee() public {
        uint128 offerAmount = 1 ether;
        coffer.setMaturityValue(2 ether); // revenue = 1 ether

        vm.prank(buyer);
        marketplace.makeOffer{value: FLAT_FEE}(bondId, offerAmount, uint64(block.timestamp + 1 days), FLAT_FEE);

        vm.prank(seller);
        marketplace.acceptOffer(bondId, buyer, offerAmount);

        uint256 expectedFee = uint256(PROFIT_FIXED) + (uint256(1 ether) * uint256(PROFIT_BPS)) / 10000;
        assertEq(weth.balanceOf(address(marketplace)), expectedFee);

        uint256 recipBefore = weth.balanceOf(feeRecipient);
        vm.prank(mpOwner);
        marketplace.claimWethFees();

        assertEq(weth.balanceOf(feeRecipient) - recipBefore, expectedFee);
        assertEq(weth.balanceOf(address(marketplace)), 0);
    }

    // ───── InsufficientFee on single-item payable wrappers ─────

    function test_cancelListing_revert_insufficientFee() public {
        vm.prank(seller);
        marketplace.list{value: FLAT_FEE}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.cancelListing{value: FLAT_FEE - 1}(bondId, FLAT_FEE);
    }

    function test_makeOffer_revert_insufficientFee() public {
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.makeOffer{value: FLAT_FEE - 1}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);
    }

    function test_cancelOffer_revert_insufficientFee() public {
        vm.prank(buyer);
        marketplace.makeOffer{value: FLAT_FEE}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.cancelOffer{value: FLAT_FEE - 1}(bondId, FLAT_FEE);
    }

    // ───── InsufficientFee on batch wrappers (not covered by batchList) ─────

    function test_batchCancelListings_revert_wrongTotalFee() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory prices = new uint128[](2);
        prices[0] = 1 ether;
        prices[1] = 2 ether;
        uint64[] memory exps = new uint64[](2);
        exps[0] = uint64(block.timestamp + 1 days);
        exps[1] = uint64(block.timestamp + 1 days);
        uint256[] memory maxFees = new uint256[](2);
        maxFees[0] = FLAT_FEE;
        maxFees[1] = FLAT_FEE;

        vm.prank(seller);
        marketplace.batchList{value: uint256(FLAT_FEE) * 2}(ids, prices, exps, maxFees);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.batchCancelListings{value: FLAT_FEE}(ids, maxFees);
    }

    function test_batchMakeOffers_revert_wrongTotalFee() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;
        uint64[] memory exps = new uint64[](2);
        exps[0] = uint64(block.timestamp + 1 days);
        exps[1] = uint64(block.timestamp + 1 days);
        uint256[] memory maxFees = new uint256[](2);
        maxFees[0] = FLAT_FEE;
        maxFees[1] = FLAT_FEE;

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.batchMakeOffers{value: FLAT_FEE}(ids, amounts, exps, maxFees);
    }

    function test_batchCancelOffers_revert_wrongTotalFee() public {
        uint256 bondId2 = bondNft.mintTo(seller, address(coffer));

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;
        uint128[] memory amounts = new uint128[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;
        uint64[] memory exps = new uint64[](2);
        exps[0] = uint64(block.timestamp + 1 days);
        exps[1] = uint64(block.timestamp + 1 days);
        uint256[] memory maxFees = new uint256[](2);
        maxFees[0] = FLAT_FEE;
        maxFees[1] = FLAT_FEE;

        vm.prank(buyer);
        marketplace.batchMakeOffers{value: uint256(FLAT_FEE) * 2}(ids, amounts, exps, maxFees);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientFee.selector);
        marketplace.batchCancelOffers{value: FLAT_FEE}(ids, maxFees);
    }

    // ───── FeeExceedsMax at makeOffer uint128 cast ─────

    function test_makeOffer_revert_feeExceedsUint128Cast() public {
        // Push locked fee above uint128.max. fixedFee = uint128.max + any positive percentageFee > uint128.max.
        vm.prank(mpOwner);
        marketplace.setFunctionFee(marketplace.acceptOffer.selector, type(uint128).max, 1);

        coffer.setMaturityValue(2 ether); // revenue = 1 ether so percentageFee > 0

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.FeeExceedsMax.selector);
        marketplace.makeOffer{value: FLAT_FEE}(bondId, 1 ether, uint64(block.timestamp + 1 days), FLAT_FEE);
    }
}
