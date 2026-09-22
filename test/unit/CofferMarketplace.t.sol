//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC721Utils} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";
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
        // The real ERC-721 reverts this custom error, and rows L10 and O8 name it: a burned bond
        // fails inside ownerOf before the marketplace reaches its own maturity check. A string
        // revert here would let those tests pass on the wrong evidence.
        require(owner != address(0), IERC721Errors.ERC721NonexistentToken(tokenId));
        return owner;
    }

    /// @dev The real Coffer deletes the bond record and burns the NFT in one call
    ///      (coffer-smart-contracts/src/Coffer.sol:699-700). Without a burn here no test can
    ///      reach the burn path at all.
    function burn(uint256 tokenId) external {
        delete _owners[tokenId];
        delete _coffers[tokenId];
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
        // The same helper the real ERC-721 runs, so a receiver that refuses produces
        // ERC721InvalidReceiver rather than a string. Row O12 names that error, and the code-bearing
        // check inside it is what makes a 7702 delegate a receiver at all (ERC721Utils.sol:32).
        ERC721Utils.checkOnERC721Received(msg.sender, from, to, tokenId, "");
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

    mapping(uint256 => uint128) private _overrides;
    mapping(uint256 => bool) private _hasOverride;

    function sHolderConditions(uint256 bondId) external view returns (uint128, uint32, uint32) {
        if (_hasOverride[bondId]) {
            return (_overrides[bondId], duration, startTs);
        }
        return (maturityValue, duration, startTs);
    }

    /// @dev Per-bond value, for tests that need several bonds to differ. Additive on purpose: the
    ///      single-argument setMaturityValue below stays the default for every bond without one.
    function setMaturityValueFor(uint256 bondId, uint128 _val) external {
        _overrides[bondId] = _val;
        _hasOverride[bondId] = true;
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

/// @dev Contract that accepts NFTs but rejects all ETH transfers, used as a buyer to exercise the
///      refund failure path on buySignedListing.
contract EthRejecter is IERC721Receiver {
    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }

    function doBuySigned(
        address mp,
        uint256 id,
        address seller,
        uint128 price,
        uint128 maturityValue,
        uint64 exp,
        uint256 nonce,
        bytes calldata sig
    ) external payable {
        CofferMarketplace(payable(mp)).buySignedListing{value: msg.value}(
            id, seller, price, maturityValue, exp, nonce, 0, sig
        );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Contract seller that validates any ERC-1271 signature and rejects ETH (it has no receive
///      function), used to exercise the WETH fallback when the seller cannot accept ETH.
contract Erc1271EthRejecter {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }
}

// ───── Tests ─────

contract CofferMarketplaceTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    uint256 constant SELLER_PK = 0xA11CE;
    uint256 constant BUYER_PK = 0xB0B;
    uint256 constant BUYER2_PK = 0xC2C;

    address public seller;
    address public buyer;
    address public buyer2;
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
        return _signListing(pk, vm.addr(pk), bId, pr, mat, exp, nonce, gNonce);
    }

    /// @dev Signs for `maker`, the account the fill names. `pk` is the key that answers for it: the
    ///      maker's own key for an EOA, the owner key behind a contract wallet.
    function _signListing(
        uint256 pk,
        address maker,
        uint256 bId,
        uint128 pr,
        uint128 mat,
        uint64 exp,
        uint256 nonce,
        uint256 gNonce
    ) internal view returns (bytes memory) {
        bytes32 digest = _listingDigest(maker, bId, pr, mat, exp, nonce, gNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(uint256 pk, uint256 bId, uint128 wAmt, uint128 mat, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        return _signOffer(pk, vm.addr(pk), bId, wAmt, mat, exp, nonce, gNonce);
    }

    function _signOffer(
        uint256 pk,
        address maker,
        uint256 bId,
        uint128 wAmt,
        uint128 mat,
        uint64 exp,
        uint256 nonce,
        uint256 gNonce
    ) internal view returns (bytes memory) {
        bytes32 digest = _offerDigest(maker, bId, wAmt, mat, exp, nonce, gNonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ───── setUp ─────

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();

        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        seller = vm.addr(SELLER_PK);
        buyer = vm.addr(BUYER_PK);
        buyer2 = vm.addr(BUYER2_PK);

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

    // Makers sign listings and offers off-chain at the current on-chain nonce. There is no registration step, the
    // taker fills directly and the contract verifies the signature at that moment. These helpers only
    // sign, they make no on-chain call.

    function _signListingNow(address who, uint256 pk, uint128 price) internal view returns (bytes memory sig) {
        return _signListingNow(who, pk, price, uint64(block.timestamp + 1 days));
    }

    function _signListingNow(address who, uint256 pk, uint128 price, uint64 exp)
        internal
        view
        returns (bytes memory sig)
    {
        uint256 nonce = marketplace.sListingNonce(who, bondId);
        uint256 gNonce = marketplace.sGlobalListingNonce(who);
        sig = _signListing(pk, who, bondId, price, 1 ether, exp, nonce, gNonce);
    }

    function _signOfferNow(address who, uint256 pk, uint128 amount) internal view returns (bytes memory sig) {
        return _signOfferNow(who, pk, amount, uint64(block.timestamp + 1 days));
    }

    function _signOfferNow(address who, uint256 pk, uint128 amount, uint64 exp)
        internal
        view
        returns (bytes memory sig)
    {
        uint256 nonce = marketplace.sOfferNonce(who, bondId);
        uint256 gNonce = marketplace.sGlobalOfferNonce(who);
        sig = _signOffer(pk, who, bondId, amount, 1 ether, exp, nonce, gNonce);
    }

    function _mintBondTo(address to) internal returns (uint256) {
        return bondNft.mintTo(to, address(coffer));
    }

    // ───── Constructor ─────

    function test_constructor() public view {
        assertEq(marketplace.I_WETH(), address(weth));
        assertEq(marketplace.I_COFFER_BOND_NFT(), address(bondNft));
        assertEq(marketplace.owner(), mpOwner);
        assertEq(marketplace.sFeeRecipient(), feeRecipient);
    }

    function test_constructor_revert_wethWithoutCode() public {
        vm.expectRevert(CofferMarketplace.NotAContract.selector);
        new CofferMarketplace(address(0), address(bondNft), mpOwner, feeRecipient);
    }

    function test_constructor_revert_bondNftWithoutCode() public {
        vm.expectRevert(CofferMarketplace.NotAContract.selector);
        new CofferMarketplace(address(weth), address(0), mpOwner, feeRecipient);
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(CofferMarketplace.ZeroAddress.selector);
        new CofferMarketplace(address(weth), address(bondNft), mpOwner, address(0));
    }

    // ───── Cancel Listing ─────

    function test_cancelListing() public {
        assertEq(marketplace.sListingNonce(seller, bondId), 0);

        vm.prank(seller);
        marketplace.cancelListing(bondId);

        assertEq(marketplace.sListingNonce(seller, bondId), 1);
    }

    function test_cancelListing_onlyAffectsOwnListing() public {
        uint256 bondId2 = bondNft.mintTo(buyer, address(coffer));

        // seller cancels their own bond, only their own per-bond nonce bumps
        vm.prank(seller);
        marketplace.cancelListing(bondId);

        assertEq(marketplace.sListingNonce(seller, bondId), 1);
        assertEq(marketplace.sListingNonce(buyer, bondId2), 0); // unaffected
    }

    function test_cancelListings_batch() public {
        uint256 bondId2 = _mintBondTo(seller);

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;

        vm.prank(seller);
        marketplace.cancelListings(ids);

        assertEq(marketplace.sListingNonce(seller, bondId), 1);
        assertEq(marketplace.sListingNonce(seller, bondId2), 1);
    }

    function test_cancelAllListings() public {
        assertEq(marketplace.sGlobalListingNonce(seller), 0);

        vm.prank(seller);
        marketplace.cancelAllListings();

        assertEq(marketplace.sGlobalListingNonce(seller), 1);
    }

    // ───── Buy Signed Listing ─────

    function test_buySignedListing() public {
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signListingNow(seller, SELLER_PK, price, exp);

        uint256 sellerBefore = seller.balance;

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint256 gNonce = marketplace.sGlobalListingNonce(seller);

        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, 1 ether, exp, nonce, gNonce, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(seller.balance - sellerBefore, price);
        // Nonce auto-incremented to prevent replay
        assertEq(marketplace.sListingNonce(seller, bondId), nonce + 1);
    }

    function test_buySignedListing_firstFillAtNonceZero() public {
        // The first listing for a bond is signed and filled at nonce 0, with no prior on-chain action
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        assertEq(marketplace.sListingNonce(seller, bondId), 0);

        bytes memory sig = _signListing(SELLER_PK, bondId, price, 1 ether, exp, 0, 0);

        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, 1 ether, exp, 0, 0, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(marketplace.sListingNonce(seller, bondId), 1);
    }

    function test_buySignedListing_withExcessRefund() public {
        uint128 price = 1 ether;
        bytes memory sig = _signListingNow(seller, SELLER_PK, price);

        uint256 buyerBefore = buyer.balance;
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint256 gNonce = marketplace.sGlobalListingNonce(seller);

        vm.prank(buyer);
        marketplace.buySignedListing{value: 2 ether}(
            bondId, seller, price, 1 ether, uint64(block.timestamp + 1 days), nonce, gNonce, sig
        );

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(buyerBefore - buyer.balance, price);
    }

    function test_buySignedListing_revert_sameParty() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, 1 ether, 1 ether, exp, nonce, 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.SameParty.selector);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_buySignedListing_revert_zeroPrice() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, 0, 1 ether, exp, nonce, 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ZeroPrice.selector);
        marketplace.buySignedListing{value: 0}(bondId, seller, 0, 1 ether, exp, nonce, 0, sig);
    }

    function test_buySignedListing_revert_invalidSignature() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        // Signed by buyer's key but claims seller as the signer
        bytes memory sig = _signListing(BUYER_PK, bondId, 1 ether, 1 ether, exp, nonce, 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_buySignedListing_revert_staleListing() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signListingNow(seller, SELLER_PK, 1 ether, exp);

        // Transfer NFT away from seller (making listing stale)
        vm.prank(seller);
        bondNft.transferFrom(seller, buyer2, bondId);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.SellerNoLongerOwnsNft.selector);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_buySignedListing_revert_bondNotOutstanding() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signListingNow(seller, SELLER_PK, 1 ether, exp);

        coffer.setMaturityValue(0);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_buySignedListing_revert_insufficientPayment() public {
        bytes memory sig = _signListingNow(seller, SELLER_PK, 1 ether);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.buySignedListing{value: 0.5 ether}(
            bondId, seller, 1 ether, 1 ether, uint64(block.timestamp + 1 days), nonce, 0, sig
        );
    }

    function test_buySignedListing_revert_expired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signListingNow(seller, SELLER_PK, 1 ether, exp);

        vm.warp(exp + 1);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_buySignedListing_revert_replay() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signListingNow(seller, SELLER_PK, 1 ether, exp);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        vm.prank(buyer);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);

        // Second buy with same nonce should revert (nonce was auto-incremented)
        vm.prank(buyer2);
        vm.deal(buyer2, 100 ether);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_buySignedListing_revert_globallyCancelled() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signListingNow(seller, SELLER_PK, 1 ether, exp);

        // Cancel all listings (bump global nonce)
        vm.prank(seller);
        marketplace.cancelAllListings();

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: 1 ether}(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_buySignedListing_sellerGetsEth() public {
        // Verify EOA seller receives ETH directly (no WETH wrapping)
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signListingNow(seller, SELLER_PK, price, exp);

        uint256 sellerBefore = seller.balance;
        uint256 wethBefore = weth.balanceOf(seller);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        uint256 gNonce = marketplace.sGlobalListingNonce(seller);

        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, 1 ether, exp, nonce, gNonce, sig);

        assertEq(seller.balance - sellerBefore, price, "Seller should receive ETH");
        assertEq(weth.balanceOf(seller) - wethBefore, 0, "Seller should not receive WETH");
        assertEq(bondNft.ownerOf(bondId), buyer);
    }

    function test_buySignedListing_sellerRejectsEth_fallsBackToWeth() public {
        // A contract seller with no receive function rejects ETH, so the marketplace wraps the
        // proceeds to WETH. The seller is an ERC-1271 wallet so its signature still verifies.
        Erc1271EthRejecter cSeller = new Erc1271EthRejecter();
        uint256 cBond = bondNft.mintTo(address(cSeller), address(coffer));
        cSeller.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(cSeller), cBond);
        uint256 gNonce = marketplace.sGlobalListingNonce(address(cSeller));

        uint256 sellerEthBefore = address(cSeller).balance;
        uint256 sellerWethBefore = weth.balanceOf(address(cSeller));

        // The wallet validates any signature, so an empty signature is accepted
        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(cBond, address(cSeller), price, 1 ether, exp, nonce, gNonce, "");

        assertEq(address(cSeller).balance - sellerEthBefore, 0, "Seller should not receive ETH");
        assertEq(weth.balanceOf(address(cSeller)) - sellerWethBefore, price, "Seller should receive WETH via fallback");
        assertEq(bondNft.ownerOf(cBond), buyer, "Buyer should own NFT");
    }

    function test_buySignedListing_buyerRefundFailsReverts() public {
        EthRejecter rejecter = new EthRejecter();

        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signListingNow(seller, SELLER_PK, 1 ether, exp);

        uint256 nonce = marketplace.sListingNonce(seller, bondId);

        // Fund the rejecter contract so it can send the purchase value
        vm.deal(address(rejecter), 2 ether);

        // rejecter sends 2 ether for a 1 ether listing, so 1 ether excess must be refunded, and the
        // refund fails because EthRejecter rejects ETH
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        rejecter.doBuySigned{value: 2 ether}(address(marketplace), bondId, seller, 1 ether, 1 ether, exp, nonce, sig);
    }

    function test_buySignedListing_priceOneWei() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, 1, 1 ether, exp, nonce, 0);

        // The profit is the whole maturity value less 1 wei, and the fee is charged on it.
        uint256 fee = ((uint256(1 ether) - 1) * marketplace.FEE_BPS()) / marketplace.BPS_DENOMINATOR();
        vm.prank(buyer);
        marketplace.buySignedListing{value: 1 + fee}(bondId, seller, 1, 1 ether, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(address(marketplace).balance, fee);
    }

    // ───── Cancel Offer ─────

    function test_cancelOffer() public {
        assertEq(marketplace.sOfferNonce(buyer, bondId), 0);

        vm.prank(buyer);
        marketplace.cancelOffer(bondId);

        assertEq(marketplace.sOfferNonce(buyer, bondId), 1);
    }

    function test_cancelOffers_batch() public {
        uint256 bondId2 = _mintBondTo(seller);

        uint256[] memory ids = new uint256[](2);
        ids[0] = bondId;
        ids[1] = bondId2;

        vm.prank(buyer);
        marketplace.cancelOffers(ids);

        assertEq(marketplace.sOfferNonce(buyer, bondId), 1);
        assertEq(marketplace.sOfferNonce(buyer, bondId2), 1);
    }

    function test_cancelAllOffers() public {
        assertEq(marketplace.sGlobalOfferNonce(buyer), 0);

        vm.prank(buyer);
        marketplace.cancelAllOffers();

        assertEq(marketplace.sGlobalOfferNonce(buyer), 1);
    }

    // ───── Accept Signed Offer ─────

    function test_acceptSignedOffer() public {
        uint128 offerAmount = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOfferNow(buyer, BUYER_PK, offerAmount, exp);

        uint256 sellerWethBefore = weth.balanceOf(seller);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        uint256 gNonce = marketplace.sGlobalOfferNonce(buyer);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, offerAmount, 1 ether, exp, nonce, gNonce, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(weth.balanceOf(seller) - sellerWethBefore, offerAmount);
        assertEq(marketplace.sOfferNonce(buyer, bondId), nonce + 1);
    }

    function test_acceptSignedOffer_revert_zeroAmount() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, 0, 1 ether, exp, nonce, 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.ZeroAmount.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 0, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_invalidSignature() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        // Signed by seller's key but claims buyer as the signer
        bytes memory sig = _signOffer(SELLER_PK, bondId, 1 ether, 1 ether, exp, nonce, 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_expired() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOfferNow(buyer, BUYER_PK, 1 ether, exp);

        vm.warp(exp + 1);

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.ExpirationNotInFuture.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_notOwner() public {
        bytes memory sig = _signOfferNow(buyer, BUYER_PK, 1 ether);

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        vm.prank(buyer2);
        vm.expectRevert(CofferMarketplace.NotOwner.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, uint64(block.timestamp + 1 days), nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_sameParty() public {
        // Seller signs an offer on their own bond
        weth.mint(seller, 10 ether);
        vm.prank(seller);
        weth.approve(address(marketplace), type(uint256).max);

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(seller, bondId);
        bytes memory sig = _signOffer(SELLER_PK, bondId, 1 ether, 1 ether, exp, nonce, 0);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.SameParty.selector);
        marketplace.acceptSignedOffer(bondId, seller, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_notApproved() public {
        uint256 seller2Pk = 0xE;
        address seller2 = vm.addr(seller2Pk);
        vm.deal(seller2, 10 ether);
        uint256 bondId2 = bondNft.mintTo(seller2, address(coffer));

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId2);
        bytes memory sig = _signOffer(BUYER_PK, bondId2, 1 ether, 1 ether, exp, nonce, 0);

        vm.prank(seller2);
        vm.expectRevert(CofferMarketplace.MarketplaceNotApproved.selector);
        marketplace.acceptSignedOffer(bondId2, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_bondNotOutstanding() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOfferNow(buyer, BUYER_PK, 1 ether, exp);

        coffer.setMaturityValue(0);

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.BondNotOutstanding.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_buyerWethDrained() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOfferNow(buyer, BUYER_PK, 1 ether, exp);

        vm.prank(buyer);
        require(weth.transfer(address(1), 100 ether), "transfer failed");

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_buyerAllowanceRevoked() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOfferNow(buyer, BUYER_PK, 1 ether, exp);

        vm.prank(buyer);
        weth.approve(address(marketplace), 0);

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InsufficientPayment.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_replay() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOfferNow(buyer, BUYER_PK, 1 ether, exp);

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);

        // First accept: seller sells
        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);

        // Second accept with same signature: nonce was auto-incremented, so it is revoked
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_revert_globallyCancelled() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        bytes memory sig = _signOfferNow(buyer, BUYER_PK, 1 ether, exp);

        vm.prank(buyer);
        marketplace.cancelAllOffers();

        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.OfferRevoked.selector);
        marketplace.acceptSignedOffer(bondId, buyer, 1 ether, 1 ether, exp, nonce, 0, sig);
    }

    function test_acceptSignedOffer_amountOneWei() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(buyer, bondId);
        bytes memory sig = _signOffer(BUYER_PK, bondId, 1, 1 ether, exp, nonce, 0);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, 1, 1 ether, exp, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondId), buyer);
        assertEq(weth.balanceOf(seller), 1);
    }

    // ───── View Functions ─────

    function test_getBondData() public view {
        (uint128 mv, uint32 dur, uint32 st, address cofferAddr) = marketplace.getBondData(bondId);
        assertEq(mv, 1 ether);
        assertEq(dur, 86400);
        assertEq(cofferAddr, address(coffer));
        assertGt(st, 0);
    }

    // ───── Fill events carry the consumed nonces ─────

    // The fill events name the exact signed message: the consumed per-bond nonce and the global
    // nonce it was signed at. The indexer attributes fills to stored rows by these
    // values, so they must be the consumed ones — not the post-bump ones, and not always zero.
    // Both nonces are advanced before the fill so a zero-defaulted emit cannot pass.

    function test_listingPurchasedEmitsConsumedNonces() public {
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);

        vm.startPrank(seller);
        marketplace.cancelListing(bondId); // per-bond nonce 0 -> 1
        marketplace.cancelAllListings(); // global nonce 0 -> 1
        vm.stopPrank();

        bytes memory sig = _signListingNow(seller, SELLER_PK, price, exp);

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.ListingPurchased(bondId, buyer, seller, price, 0, 1, 1);

        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, 1 ether, exp, 1, 1, sig);

        // The event carried the consumed value; the counter has already moved past it.
        assertEq(marketplace.sListingNonce(seller, bondId), 2);
    }

    function test_offerAcceptedEmitsConsumedNonces() public {
        uint128 amount = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);

        vm.startPrank(buyer);
        marketplace.cancelOffer(bondId); // per-bond nonce 0 -> 1
        marketplace.cancelAllOffers(); // global nonce 0 -> 1
        vm.stopPrank();

        bytes memory sig = _signOfferNow(buyer, BUYER_PK, amount, exp);

        vm.expectEmit(true, true, true, true, address(marketplace));
        emit CofferMarketplace.OfferAccepted(bondId, buyer, seller, amount, 0, 1, 1);

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, buyer, amount, 1 ether, exp, 1, 1, sig);

        assertEq(marketplace.sOfferNonce(buyer, bondId), 2);
    }
}
