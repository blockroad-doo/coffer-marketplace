//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CofferMarketplace} from "../../src/CofferMarketplace.sol";

// ───── Mock Contracts ─────

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
    mapping(uint256 => uint128) public maturityValues;

    function sHolderConditions(uint256 bondId) external view returns (uint128, uint32, uint32, bool) {
        return (maturityValues[bondId], 86400, uint32(block.timestamp - 86401), false);
    }

    function setMaturityValue(uint256 bondId, uint128 val) external {
        maturityValues[bondId] = val;
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

/// @dev Safe-like ERC-1271 wallet. isValidSignature returns the magic value if and only if the
///      provided signature recovers to a configured owner EOA, with a toggle to revoke authorization.
contract MockERC1271Wallet is IERC721Receiver {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;

    address public owner;
    bool public authorized = true;

    constructor(address _owner) {
        owner = _owner;
    }

    function setAuthorized(bool a) external {
        authorized = a;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (!authorized) return INVALID;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) return MAGIC;
        return INVALID;
    }

    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }

    function approveWeth(address weth_, address operator, uint256 amount) external {
        MockWETH(weth_).approve(operator, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev A wallet that validates any signature, used to prove a malicious wallet is still confined to
///      the bonds it owns and approved.
contract PromiscuousWallet is IERC721Receiver {
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }

    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev A wallet whose isValidSignature reverts, which SignatureChecker must treat as not valid.
contract RevertingWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("nope");
    }

    function approveNft(address nft, address operator) external {
        MockBondNft(nft).setApprovalForAll(operator, true);
    }
}

// ───── Tests ─────

contract VerifyErc1271SupportTest is Test {
    CofferMarketplace public marketplace;
    MockBondNft public bondNft;
    MockCoffer public coffer;
    MockWETH public weth;

    uint256 constant SELLER_PK = 0xA11CE;
    uint256 constant BUYER_PK = 0xB0B;
    uint256 constant BUYER2_PK = 0xC2C;
    uint256 constant WALLET_OWNER_PK = 0x5160;

    address public seller;
    address public buyer;
    address public buyer2;
    address public walletOwner;
    address public mpOwner = makeAddr("mpOwner");
    address public feeRecipient = makeAddr("feeRecipient");

    uint256 public bondId;

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

    function _signListing(uint256 pk, uint256 bId, uint128 pr, uint64 exp, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(LISTING_TYPEHASH, bId, pr, exp, nonce, gNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signOffer(uint256 pk, uint256 bId, uint128 wAmt, uint64 exp, uint256 maxF, uint256 nonce, uint256 gNonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(OFFER_TYPEHASH, bId, wAmt, exp, maxF, nonce, gNonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Flip a 65-byte signature to its high-s counterpart, which ECDSA must reject.
    function _malleate(bytes memory sig) internal pure returns (bytes memory) {
        require(sig.length == 65, "len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sFlipped = bytes32(n - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        return abi.encodePacked(r, sFlipped, vFlipped);
    }

    function setUp() public {
        vm.warp(100_000);
        coffer = new MockCoffer();
        bondNft = new MockBondNft();
        weth = new MockWETH();
        marketplace = new CofferMarketplace(address(weth), address(bondNft), mpOwner, feeRecipient);

        seller = vm.addr(SELLER_PK);
        buyer = vm.addr(BUYER_PK);
        buyer2 = vm.addr(BUYER2_PK);
        walletOwner = vm.addr(WALLET_OWNER_PK);

        bondId = bondNft.mintTo(seller, address(coffer));
        coffer.setMaturityValue(bondId, 5 ether);

        vm.prank(seller);
        bondNft.setApprovalForAll(address(marketplace), true);

        vm.deal(buyer, 100 ether);
        vm.deal(buyer2, 100 ether);

        weth.mint(buyer, 100 ether);
        vm.prank(buyer);
        weth.approve(address(marketplace), type(uint256).max);
    }

    // ───── Happy paths: a contract wallet can trade ─────

    function test_contractWalletSeller_listingBought() public {
        MockERC1271Wallet w = new MockERC1271Wallet(walletOwner);
        uint256 wBond = bondNft.mintTo(address(w), address(coffer));
        coffer.setMaturityValue(wBond, 5 ether);
        w.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(w), wBond);
        bytes memory sig = _signListing(WALLET_OWNER_PK, wBond, price, exp, nonce, 0);

        uint256 wBalBefore = address(w).balance;
        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(wBond, address(w), price, exp, nonce, 0, 0, sig);

        assertEq(bondNft.ownerOf(wBond), buyer, "buyer should own the bond");
        assertEq(address(w).balance - wBalBefore, price, "wallet should receive ETH");
    }

    function test_contractWalletBuyer_offerAccepted() public {
        MockERC1271Wallet w = new MockERC1271Wallet(walletOwner);
        weth.mint(address(w), 100 ether);
        w.approveWeth(address(weth), address(marketplace), type(uint256).max);

        uint128 amount = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(address(w), bondId);
        bytes memory sig = _signOffer(WALLET_OWNER_PK, bondId, amount, exp, type(uint256).max, nonce, 0);

        uint256 sellerWethBefore = weth.balanceOf(seller);
        uint256 walletWethBefore = weth.balanceOf(address(w));

        vm.prank(seller);
        marketplace.acceptSignedOffer(bondId, address(w), amount, exp, type(uint256).max, nonce, 0, sig);

        assertEq(bondNft.ownerOf(bondId), address(w), "wallet should own the bond");
        assertEq(weth.balanceOf(seller) - sellerWethBefore, amount, "seller should receive WETH");
        assertEq(walletWethBefore - weth.balanceOf(address(w)), amount, "wallet should pay WETH");
    }

    // ───── Re-validation at fill (revocable ERC-1271) ─────

    function test_revokeBetweenSignAndBuy_failsAtFill() public {
        MockERC1271Wallet w = new MockERC1271Wallet(walletOwner);
        uint256 wBond = bondNft.mintTo(address(w), address(coffer));
        coffer.setMaturityValue(wBond, 5 ether);
        w.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(w), wBond);
        bytes memory sig = _signListing(WALLET_OWNER_PK, wBond, price, exp, nonce, 0);

        // The wallet revokes its authorization after signing
        w.setAuthorized(false);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: price}(wBond, address(w), price, exp, nonce, 0, 0, sig);
    }

    function test_revokeBetweenSignAndAccept_failsAtFill() public {
        MockERC1271Wallet w = new MockERC1271Wallet(walletOwner);
        weth.mint(address(w), 100 ether);
        w.approveWeth(address(weth), address(marketplace), type(uint256).max);

        uint128 amount = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sOfferNonce(address(w), bondId);
        bytes memory sig = _signOffer(WALLET_OWNER_PK, bondId, amount, exp, type(uint256).max, nonce, 0);

        w.setAuthorized(false);

        vm.prank(seller);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.acceptSignedOffer(bondId, address(w), amount, exp, type(uint256).max, nonce, 0, sig);
    }

    // ───── Rejection cases ─────

    function test_rejectsWrongOwnerSignature() public {
        MockERC1271Wallet w = new MockERC1271Wallet(walletOwner);
        uint256 wBond = bondNft.mintTo(address(w), address(coffer));
        coffer.setMaturityValue(wBond, 5 ether);
        w.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(w), wBond);
        // Signed by a key that is NOT the wallet's owner
        bytes memory sig = _signListing(BUYER_PK, wBond, price, exp, nonce, 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: price}(wBond, address(w), price, exp, nonce, 0, 0, sig);
    }

    function test_rejectsRevertingWallet() public {
        RevertingWallet w = new RevertingWallet();
        uint256 wBond = bondNft.mintTo(address(w), address(coffer));
        coffer.setMaturityValue(wBond, 5 ether);
        w.approveNft(address(bondNft), address(marketplace));

        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(w), wBond);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: 1 ether}(wBond, address(w), 1 ether, exp, nonce, 0, 0, "");
    }

    // ───── EOA path still works (no domain bump, existing signatures verify) ─────

    function test_eoaRegression_buyStillWorks() public {
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, exp, nonce, 0);

        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(bondId, seller, price, exp, nonce, 0, 0, sig);
        assertEq(bondNft.ownerOf(bondId), buyer);
    }

    function test_malleableSignatureRejected() public {
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, exp, nonce, 0);
        bytes memory bad = _malleate(sig);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: price}(bondId, seller, price, exp, nonce, 0, 0, bad);
    }

    function test_zeroAddressSellerRejected() public {
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(seller, bondId);
        bytes memory sig = _signListing(SELLER_PK, bondId, price, exp, nonce, 0);

        // A zero-address seller can never own the bond, so the ownership check rejects the fill before
        // signature verification is reached. The contract never treats address(0) as a valid signer.
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.SellerNoLongerOwnsNft.selector);
        marketplace.buySignedListing{value: price}(bondId, address(0), price, exp, nonce, 0, 0, sig);
    }

    function test_wrongSignerForEoaRejected() public {
        // buyer2 genuinely owns and approves a bond, so the call clears the ownership and approval
        // checks and reaches signature verification, which is what this test exercises.
        uint256 b2Bond = bondNft.mintTo(buyer2, address(coffer));
        coffer.setMaturityValue(b2Bond, 5 ether);
        vm.prank(buyer2);
        bondNft.setApprovalForAll(address(marketplace), true);

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(buyer2, b2Bond);
        // Valid signature from SELLER_PK, but claims buyer2 as the signer
        bytes memory sig = _signListing(SELLER_PK, b2Bond, price, exp, nonce, 0);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.InvalidSignature.selector);
        marketplace.buySignedListing{value: price}(b2Bond, buyer2, price, exp, nonce, 0, 0, sig);
    }

    // ───── Confinement: a magic-for-everything wallet only harms itself ─────

    function test_confinement_promiscuousWalletCanSellOwnBond() public {
        PromiscuousWallet w = new PromiscuousWallet();
        uint256 wBond = bondNft.mintTo(address(w), address(coffer));
        coffer.setMaturityValue(wBond, 5 ether);
        w.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(w), wBond);

        vm.prank(buyer);
        marketplace.buySignedListing{value: price}(wBond, address(w), price, exp, nonce, 0, 0, "");
        assertEq(bondNft.ownerOf(wBond), buyer);
    }

    function test_confinement_promiscuousWalletCannotSellBondItDoesNotOwn() public {
        PromiscuousWallet w = new PromiscuousWallet();
        // The wallet validates any signature, but it does not own bondId (the EOA seller does), so
        // the ownership check confines it
        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        uint256 nonce = marketplace.sListingNonce(address(w), bondId);

        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.SellerNoLongerOwnsNft.selector);
        marketplace.buySignedListing{value: price}(bondId, address(w), price, exp, nonce, 0, 0, "");
    }

    // ───── A contract wallet can revoke via cancelAll ─────

    function test_contractWalletCanCancelAllListings() public {
        MockERC1271Wallet w = new MockERC1271Wallet(walletOwner);
        uint256 wBond = bondNft.mintTo(address(w), address(coffer));
        coffer.setMaturityValue(wBond, 5 ether);
        w.approveNft(address(bondNft), address(marketplace));

        uint128 price = 1 ether;
        uint64 exp = uint64(block.timestamp + 1 days);
        // Owner signs at global nonce 0
        bytes memory sig = _signListing(WALLET_OWNER_PK, wBond, price, exp, 0, 0);

        // The wallet revokes all its listings by calling cancelAllListings as msg.sender
        vm.prank(address(w));
        marketplace.cancelAllListings();

        // The order signed at global nonce 0 is now revoked
        vm.prank(buyer);
        vm.expectRevert(CofferMarketplace.ListingRevoked.selector);
        marketplace.buySignedListing{value: price}(wBond, address(w), price, exp, 0, 0, 0, sig);
    }
}
