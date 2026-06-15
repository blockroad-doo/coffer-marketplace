//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ICofferBondNft} from "./interfaces/ICofferBondNft.sol";
import {ICoffer} from "./interfaces/ICoffer.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title CofferMarketplace
/// @author Coffer
/// @notice Secondary marketplace for Coffer bond NFTs using EIP-712 signed listings and offers.
/// @notice Makers sign listings and offers off-chain at no cost and the orders live in an off-chain
///         order book. A taker fills an order on-chain with buySignedListing or acceptSignedOffer,
///         which verify the maker signature at that moment. Both EOA and ERC-1271 contract wallets,
///         such as Safe and ERC-4337 accounts, are supported. Makers cancel on-chain by bumping a
///         nonce, which is the only way to revoke an outstanding signature.
/// @notice A profit-based percentage fee is charged only on a completed trade, on buySignedListing
///         (paid in ETH) and on acceptSignedOffer (paid in WETH). See the Fee Flow section of the
///         README for the fee philosophy.
contract CofferMarketplace is Ownable2Step, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ───── Errors ─────

    error ZeroAddress();
    error ZeroPrice();
    error ZeroAmount();
    error NotOwner();
    error BondNotOutstanding();
    error MaturityValueMismatch();
    error SellerNoLongerOwnsNft();
    error MarketplaceNotApproved();
    error ExpirationNotInFuture();
    error InsufficientPayment();
    error FeeExceedsMax();
    error FeeTooHigh();
    error NothingToClaim();
    error NothingToClaimWeth();
    error InvalidSignature();
    error ListingRevoked();
    error OfferRevoked();
    error SameParty();
    error RenounceOwnershipDisabled();

    // ───── EIP-712 Typehashes ─────

    /* solhint-disable gas-small-strings, max-line-length */
    bytes32 private constant LISTING_TYPEHASH = keccak256(
        "Listing(uint256 bondId,uint128 price,uint128 maturityValue,uint64 expiration,uint256 nonce,uint256 globalNonce)"
    );
    bytes32 private constant OFFER_TYPEHASH = keccak256(
        "Offer(uint256 bondId,uint128 wethAmount,uint128 maturityValue,uint64 expiration,uint256 maxFee,uint256 nonce,uint256 globalNonce)"
    );
    /* solhint-enable gas-small-strings, max-line-length */

    // ───── Constants ─────

    /// @notice Basis points denominator (100% = 10000)
    uint16 public constant BPS_DENOMINATOR = 10000;

    // ───── State ─────

    /// @notice Immutable WETH token contract address
    address public immutable I_WETH;
    /// @notice Immutable CofferBondNft contract address
    address public immutable I_COFFER_BOND_NFT;

    /// @notice The address that receives collected fees on claim
    address public sFeeRecipient;
    /// @notice Profit-based fee in basis points charged on buySignedListing, paid in ETH
    uint16 public sListingFeeBps;
    /// @notice Profit-based fee in basis points charged on acceptSignedOffer, paid in WETH
    uint16 public sOfferFeeBps;

    /// @notice Global listing nonce per seller, bumped by cancelAllListings
    mapping(address account => uint256 nonce) public sGlobalListingNonce;
    /// @notice Per-bond listing nonce per seller, bumped on fill or per-bond cancel
    mapping(address account => mapping(uint256 bondId => uint256 nonce)) public sListingNonce;

    /// @notice Global offer nonce per buyer, bumped by cancelAllOffers
    mapping(address account => uint256 nonce) public sGlobalOfferNonce;
    /// @notice Per-bond offer nonce per buyer, bumped on fill or per-bond cancel
    mapping(address account => mapping(uint256 bondId => uint256 nonce)) public sOfferNonce;

    // ───── Events ─────

    /* solhint-disable gas-indexed-events */

    /// @notice Emitted when a single listing is cancelled
    /// @param seller The seller address
    /// @param bondId The bond token ID
    /// @param newNonce The new per-bond nonce after cancellation
    event ListingCancelled(address indexed seller, uint256 indexed bondId, uint256 newNonce);
    /// @notice Emitted when multiple listings are cancelled in one tx
    /// @param seller The seller address
    /// @param bondIds The bond token IDs cancelled
    /// @param newNonces The new per-bond nonces after cancellation
    event ListingsCancelled(address indexed seller, uint256[] bondIds, uint256[] newNonces);
    /// @notice Emitted when all listings are cancelled (global nonce bump)
    /// @param seller The seller address
    /// @param newGlobalNonce The new global nonce after cancellation
    event AllListingsCancelled(address indexed seller, uint256 newGlobalNonce);
    /// @notice Emitted when a listed bond NFT is purchased via signed listing
    /// @param bondId The bond token ID
    /// @param buyer The buyer address
    /// @param seller The seller address
    /// @param price The listing price in wei
    /// @param fee The ETH fee collected by the marketplace
    event ListingPurchased(
        uint256 indexed bondId, address indexed buyer, address indexed seller, uint128 price, uint256 fee
    );

    /// @notice Emitted when a single offer is cancelled
    /// @param buyer The buyer address
    /// @param bondId The bond token ID
    /// @param newNonce The new per-bond nonce after cancellation
    event OfferCancelled(address indexed buyer, uint256 indexed bondId, uint256 newNonce);
    /// @notice Emitted when multiple offers are cancelled in one tx
    /// @param buyer The buyer address
    /// @param bondIds The bond token IDs cancelled
    /// @param newNonces The new per-bond nonces after cancellation
    event OffersCancelled(address indexed buyer, uint256[] bondIds, uint256[] newNonces);
    /// @notice Emitted when all offers are cancelled (global nonce bump)
    /// @param buyer The buyer address
    /// @param newGlobalNonce The new global nonce after cancellation
    event AllOffersCancelled(address indexed buyer, uint256 newGlobalNonce);
    /// @notice Emitted when a signed offer is accepted by the NFT owner
    /// @param bondId The bond token ID
    /// @param buyer The offerer address
    /// @param seller The seller address
    /// @param wethAmount The WETH amount of the accepted offer
    /// @param fee The WETH fee collected by the marketplace
    event OfferAccepted(
        uint256 indexed bondId, address indexed buyer, address indexed seller, uint128 wethAmount, uint256 fee
    );

    /// @notice Emitted when the fee recipient is updated
    /// @param recipient The new fee recipient address
    event FeeRecipientSet(address indexed recipient);
    /// @notice Emitted when the profit-based fee basis points are configured
    /// @param listingFeeBps The buySignedListing fee in basis points
    /// @param offerFeeBps The acceptSignedOffer fee in basis points
    event FeeBpsSet(uint16 listingFeeBps, uint16 offerFeeBps);
    /// @notice Emitted when ETH fees are claimed
    /// @param recipient The address that received the fees
    /// @param amount The amount of ETH claimed
    event FeesClaimed(address indexed recipient, uint256 amount);
    /// @notice Emitted when WETH fees are claimed
    /// @param recipient The address that received the fees
    /// @param amount The amount of WETH claimed
    event WethFeesClaimed(address indexed recipient, uint256 amount);

    /* solhint-enable gas-indexed-events */

    // ───── Constructor ─────

    constructor(address _weth, address _cofferBondNft, address _owner, address _feeRecipient)
        Ownable(_owner)
        EIP712("CofferMarketplace", "3")
    {
        require(_weth != address(0), ZeroAddress());
        require(_cofferBondNft != address(0), ZeroAddress());
        require(_feeRecipient != address(0), ZeroAddress());
        I_WETH = _weth;
        I_COFFER_BOND_NFT = _cofferBondNft;
        sFeeRecipient = _feeRecipient;
        emit FeeRecipientSet(_feeRecipient);
    }

    // ───── Admin ─────

    /// @notice Renouncing ownership is permanently disabled.
    /// @dev Overrides Ownable.renounceOwnership to always revert, so the owner can never become
    ///      address(0). That would otherwise permanently freeze fee configuration and lock accrued
    ///      fees, since the contract is non-upgradeable. Transfer ownership via the two-step
    ///      transferOwnership and acceptOwnership flow instead.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Update the fee recipient address
    /// @param _recipient The new fee recipient address
    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), ZeroAddress());
        sFeeRecipient = _recipient;
        emit FeeRecipientSet(_recipient);
    }

    /// @notice Configure the profit-based fees, in basis points, for the two trade actions
    /// @param _listingFeeBps The buySignedListing fee in basis points (paid in ETH)
    /// @param _offerFeeBps The acceptSignedOffer fee in basis points (paid in WETH)
    function setFeeBps(uint16 _listingFeeBps, uint16 _offerFeeBps) external onlyOwner {
        require(_listingFeeBps < BPS_DENOMINATOR, FeeTooHigh());
        require(_offerFeeBps < BPS_DENOMINATOR, FeeTooHigh());
        sListingFeeBps = _listingFeeBps;
        sOfferFeeBps = _offerFeeBps;
        emit FeeBpsSet(_listingFeeBps, _offerFeeBps);
    }

    /// @notice Claim accumulated ETH fees to the fee recipient.
    /// @dev Sweeps the entire ETH balance rather than a tracked fee ledger. The contract holds ETH
    ///      only from the buySignedListing fee, so the balance is the accrued fee. Any ETH force-fed by
    ///      selfdestruct or a coinbase payment is also paid to the fee recipient on claim. Per-trade
    ///      fees are auditable off-chain from the ListingPurchased and FeesClaimed events.
    function claimFees() external onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, NothingToClaim());
        address recipient = sFeeRecipient;
        Address.sendValue(payable(recipient), amount);
        emit FeesClaimed(recipient, amount);
    }

    /// @notice Claim accumulated WETH fees to the fee recipient.
    /// @dev Sweeps the entire WETH balance rather than a tracked fee ledger. The contract holds WETH
    ///      only from the acceptSignedOffer fee, so the balance is the accrued fee. Any WETH sent to
    ///      the contract outside the fee flow is also paid to the fee recipient on claim. Per-trade
    ///      fees are auditable off-chain from the OfferAccepted and WethFeesClaimed events.
    function claimWethFees() external onlyOwner {
        uint256 amount = IERC20(I_WETH).balanceOf(address(this));
        require(amount > 0, NothingToClaimWeth());
        address recipient = sFeeRecipient;
        IERC20(I_WETH).safeTransfer(recipient, amount);
        emit WethFeesClaimed(recipient, amount);
    }

    // ───── Internal: Signature Verification ─────

    /// @dev Verification accepts both EOA signatures (ECDSA) and ERC-1271 contract-wallet signatures
    ///      through SignatureChecker, validated against the claimed signer. The signer is an explicit
    ///      argument rather than recovered, because a contract wallet has no key to recover. Because
    ///      ERC-1271 validity is revocable, buySignedListing and acceptSignedOffer verify at fill time.

    function _verifyListingSig(
        address _signer,
        uint256 _bondId,
        uint128 _price,
        uint128 _maturityValue,
        uint64 _expiration,
        uint256 _nonce,
        uint256 _globalNonce,
        bytes calldata _sig
    ) internal view {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(LISTING_TYPEHASH, _bondId, _price, _maturityValue, _expiration, _nonce, _globalNonce))
        );
        require(SignatureChecker.isValidSignatureNowCalldata(_signer, digest, _sig), InvalidSignature());
    }

    function _verifyOfferSig(
        address _signer,
        uint256 _bondId,
        uint128 _wethAmount,
        uint128 _maturityValue,
        uint64 _expiration,
        uint256 _maxFee,
        uint256 _nonce,
        uint256 _globalNonce,
        bytes calldata _sig
    ) internal view {
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                // solhint-disable-next-line max-line-length
                abi.encode(
                    OFFER_TYPEHASH, _bondId, _wethAmount, _maturityValue, _expiration, _maxFee, _nonce, _globalNonce
                )
            )
        );
        require(SignatureChecker.isValidSignatureNowCalldata(_signer, digest, _sig), InvalidSignature());
    }

    // ───── Listing Functions ─────

    /// @notice Cancel a single bond listing by bumping the per-bond nonce
    /// @dev Advances the nonce by exactly one. If the seller has pre-signed a listing at the next
    ///      nonce, that listing becomes fillable. Sign only at the current on-chain nonce.
    /// @param _bondId The bond token ID to cancel
    function cancelListing(uint256 _bondId) external {
        uint256 newNonce = ++sListingNonce[msg.sender][_bondId];
        emit ListingCancelled(msg.sender, _bondId, newNonce);
    }

    /// @notice Cancel multiple bond listings in one transaction
    /// @dev Passing the same bond id k times advances that bond's nonce by k atomically, which clears
    ///      a queue of k pre-signed listings for that bond without affecting other bonds.
    /// @param _bondIds The bond token IDs to cancel
    function cancelListings(uint256[] calldata _bondIds) external {
        uint256 length = _bondIds.length;
        uint256[] memory newNonces = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            newNonces[i] = ++sListingNonce[msg.sender][_bondIds[i]];
        }
        emit ListingsCancelled(msg.sender, _bondIds, newNonces);
    }

    /// @notice Cancel ALL active listings for the caller by bumping the global nonce
    /// @dev Invalidates every outstanding listing signature across all bonds, the safe sweep when a
    ///      seller is unsure what is still signed.
    function cancelAllListings() external {
        uint256 newGlobalNonce = ++sGlobalListingNonce[msg.sender];
        emit AllListingsCancelled(msg.sender, newGlobalNonce);
    }

    /// @notice Purchase a bond via an EIP-712 signed listing
    /// @param _bondId The bond token ID
    /// @param _seller The seller address (signer of the listing)
    /// @param _price The listing price from the signed message
    /// @param _maturityValue The bond maturity value from the signed message, must equal the live value at fill
    /// @param _expiration The listing expiration from the signed message
    /// @param _nonce The signed nonce (must equal current per-bond nonce)
    /// @param _globalNonce The signed global nonce (must equal current global nonce)
    /// @param _maxFee The maximum ETH buy fee the buyer is willing to pay
    /// @param _sig The EIP-712 signature
    function buySignedListing(
        uint256 _bondId,
        address _seller,
        uint128 _price,
        uint128 _maturityValue,
        uint64 _expiration,
        uint256 _nonce,
        uint256 _globalNonce,
        uint256 _maxFee,
        bytes calldata _sig
    ) external payable nonReentrant {
        require(msg.sender != _seller, SameParty());
        require(_price > 0, ZeroPrice());

        require(_nonce == sListingNonce[_seller][_bondId], ListingRevoked());
        require(_globalNonce == sGlobalListingNonce[_seller], ListingRevoked());

        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).ownerOf(_bondId) == _seller, SellerNoLongerOwnsNft());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line max-line-length
        require(ICofferBondNft(I_COFFER_BOND_NFT).isApprovedForAll(_seller, address(this)), MarketplaceNotApproved());

        _validateTrade(_expiration);

        _verifyListingSig(_seller, _bondId, _price, _maturityValue, _expiration, _nonce, _globalNonce, _sig);

        uint128 maturityValue = _getBondMaturity(_bondId);
        require(maturityValue != 0, BondNotOutstanding());
        require(maturityValue == _maturityValue, MaturityValueMismatch());
        uint256 profit = maturityValue > _price ? uint256(maturityValue) - uint256(_price) : 0;
        uint256 fee = _feeOnProfit(profit, sListingFeeBps, _maxFee);

        uint256 total = uint256(_price) + fee;
        // solhint-disable-next-line gas-strict-inequalities
        require(msg.value >= total, InsufficientPayment());

        ++sListingNonce[_seller][_bondId];

        _executeBuy(_bondId, _seller, _price, fee, msg.value - total);
    }

    // ───── Offer Functions ─────

    /// @notice Cancel a single offer by bumping the per-bond nonce
    /// @dev Advances the nonce by exactly one. If the buyer has pre-signed an offer at the next
    ///      nonce, that offer becomes fillable. Sign only at the current on-chain nonce.
    /// @param _bondId The bond token ID
    function cancelOffer(uint256 _bondId) external {
        uint256 newNonce = ++sOfferNonce[msg.sender][_bondId];
        emit OfferCancelled(msg.sender, _bondId, newNonce);
    }

    /// @notice Cancel multiple offers in one transaction
    /// @dev Passing the same bond id k times advances that bond's nonce by k atomically, which clears
    ///      a queue of k pre-signed offers for that bond without affecting other bonds.
    /// @param _bondIds The bond token IDs to cancel
    function cancelOffers(uint256[] calldata _bondIds) external {
        uint256 length = _bondIds.length;
        uint256[] memory newNonces = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            newNonces[i] = ++sOfferNonce[msg.sender][_bondIds[i]];
        }
        emit OffersCancelled(msg.sender, _bondIds, newNonces);
    }

    /// @notice Cancel ALL active offers for the caller by bumping the global nonce
    /// @dev Invalidates every outstanding offer signature across all bonds, the safe sweep when a
    ///      buyer is unsure what is still signed.
    function cancelAllOffers() external {
        uint256 newGlobalNonce = ++sGlobalOfferNonce[msg.sender];
        emit AllOffersCancelled(msg.sender, newGlobalNonce);
    }

    /// @notice Accept an EIP-712 signed offer. The offerer pays the WETH fee computed from
    ///         current config. Reverts with FeeExceedsMax if that fee exceeds the signed maxOfferFee.
    /// @param _bondId The bond token ID
    /// @param _buyer The offerer address (signer of the offer)
    /// @param _wethAmount The WETH offer amount from the signed message
    /// @param _maturityValue The bond maturity value from the signed message, must equal the live value at fill
    /// @param _expiration The offer expiration from the signed message
    /// @param _maxOfferFee The maximum WETH fee signed by the offerer
    /// @param _nonce The signed nonce (must equal current per-bond nonce)
    /// @param _globalNonce The signed global nonce (must equal current global nonce)
    /// @param _sig The EIP-712 signature
    function acceptSignedOffer(
        uint256 _bondId,
        address _buyer,
        uint128 _wethAmount,
        uint128 _maturityValue,
        uint64 _expiration,
        uint256 _maxOfferFee,
        uint256 _nonce,
        uint256 _globalNonce,
        bytes calldata _sig
    ) external nonReentrant {
        require(msg.sender != _buyer, SameParty());
        require(_wethAmount > 0, ZeroAmount());

        require(_nonce == sOfferNonce[_buyer][_bondId], OfferRevoked());
        require(_globalNonce == sGlobalOfferNonce[_buyer], OfferRevoked());

        // slither-disable-next-line calls-loop
        require(ICofferBondNft(I_COFFER_BOND_NFT).ownerOf(_bondId) == msg.sender, NotOwner());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line max-line-length
        require(ICofferBondNft(I_COFFER_BOND_NFT).isApprovedForAll(msg.sender, address(this)), MarketplaceNotApproved());

        _validateTrade(_expiration);

        // solhint-disable-next-line max-line-length
        _verifyOfferSig(
            _buyer, _bondId, _wethAmount, _maturityValue, _expiration, _maxOfferFee, _nonce, _globalNonce, _sig
        );

        uint128 maturityValue = _getBondMaturity(_bondId);
        require(maturityValue != 0, BondNotOutstanding());
        require(maturityValue == _maturityValue, MaturityValueMismatch());
        uint256 revenue = maturityValue > _wethAmount ? uint256(maturityValue) - uint256(_wethAmount) : 0;
        uint256 fee = _feeOnProfit(revenue, sOfferFeeBps, _maxOfferFee);

        ++sOfferNonce[_buyer][_bondId];

        _executeAccept(_bondId, _buyer, _wethAmount, fee);
    }

    // ───── View Functions ─────

    /// @notice Get bond data from the associated Coffer
    /// @param _bondId The bond token ID
    /// @return maturityValue The bond maturity value
    /// @return duration The bond duration in seconds
    /// @return startTimestamp The bond start timestamp
    /// @return cofferAddress The Coffer address
    function getBondData(uint256 _bondId)
        external
        view
        returns (uint128 maturityValue, uint32 duration, uint32 startTimestamp, address cofferAddress)
    {
        cofferAddress = ICofferBondNft(I_COFFER_BOND_NFT).cofferOf(_bondId);
        // slither-disable-next-line unused-return
        (maturityValue, duration, startTimestamp,) = ICoffer(cofferAddress).sHolderConditions(_bondId);
    }

    // ───── Internal: Fee Math ─────

    /// @notice Compute a profit-based fee, profit * bps / BPS_DENOMINATOR, capped at the caller maximum.
    /// @param _profit The profit the percentage is applied to
    /// @param _bps The fee in basis points
    /// @param _maxFee The maximum fee the caller is willing to pay
    /// @return fee The calculated fee
    function _feeOnProfit(uint256 _profit, uint16 _bps, uint256 _maxFee) internal pure returns (uint256 fee) {
        fee = (_profit * uint256(_bps)) / BPS_DENOMINATOR;
        // solhint-disable-next-line gas-strict-inequalities
        require(fee <= _maxFee, FeeExceedsMax());
    }

    // ───── Internal: Bond Helpers ─────

    /// @notice Read the maturity value of a bond from its associated Coffer
    /// @param _bondId The bond token ID
    /// @return maturityValue The bond maturity value in wei
    function _getBondMaturity(uint256 _bondId) internal view returns (uint128 maturityValue) {
        // slither-disable-next-line calls-loop
        address cofferAddr = ICofferBondNft(I_COFFER_BOND_NFT).cofferOf(_bondId);
        // slither-disable-next-line unused-return,calls-loop
        (maturityValue,,,) = ICoffer(cofferAddr).sHolderConditions(_bondId);
    }

    // ───── Internal: Trade Execution ─────

    /// @notice Shared pre-trade check: expiry. Bond value is gated by the signed maturityValue at fill.
    /// @param _expiration The expiration timestamp
    function _validateTrade(uint64 _expiration) internal view {
        // solhint-disable-next-line gas-strict-inequalities
        require(block.timestamp <= _expiration, ExpirationNotInFuture()); // forge-lint: disable-line(block-timestamp)
    }

    /// @notice Finalise a signed-listing purchase: NFT, ETH/WETH, refund, event.
    /// @param _bondId The bond token ID
    /// @param _seller The seller address
    /// @param _price The listing price in wei
    /// @param _fee The ETH fee collected
    /// @param _excess Excess ETH to refund to buyer
    function _executeBuy(uint256 _bondId, address _seller, uint128 _price, uint256 _fee, uint256 _excess) internal {
        // slither-disable-next-line arbitrary-send-erc20,calls-loop
        ICofferBondNft(I_COFFER_BOND_NFT).safeTransferFrom(_seller, msg.sender, _bondId);

        // slither-disable-next-line arbitrary-send-eth,calls-loop
        bool okSeller = _safeTransferETH(_seller, _price);
        if (!okSeller) {
            IWETH(I_WETH).deposit{value: _price}();
            IERC20(I_WETH).safeTransfer(_seller, _price);
        }

        if (_excess > 0) {
            // slither-disable-next-line arbitrary-send-eth
            require(_safeTransferETH(msg.sender, _excess), InsufficientPayment());
        }

        emit ListingPurchased(_bondId, msg.sender, _seller, _price, _fee);
    }

    /// @notice Finalise a signed-offer acceptance: WETH checks, transfers, NFT, event.
    /// @param _bondId The bond token ID
    /// @param _buyer The offerer address
    /// @param _wethAmount The WETH offer amount
    /// @param _fee The WETH fee collected
    function _executeAccept(uint256 _bondId, address _buyer, uint128 _wethAmount, uint256 _fee) internal {
        uint256 totalWeth = uint256(_wethAmount) + _fee;
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).balanceOf(_buyer) >= totalWeth, InsufficientPayment());
        // slither-disable-next-line calls-loop
        // solhint-disable-next-line gas-strict-inequalities
        require(IWETH(I_WETH).allowance(_buyer, address(this)) >= totalWeth, InsufficientPayment());

        // slither-disable-next-line arbitrary-send-erc20
        IERC20(I_WETH).safeTransferFrom(_buyer, msg.sender, _wethAmount);
        if (_fee > 0) {
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(I_WETH).safeTransferFrom(_buyer, address(this), _fee);
        }

        // slither-disable-next-line calls-loop
        ICofferBondNft(I_COFFER_BOND_NFT).safeTransferFrom(msg.sender, _buyer, _bondId);

        emit OfferAccepted(_bondId, _buyer, msg.sender, _wethAmount, _fee);
    }

    /// @notice Transfer ETH without copying returndata, preventing returndata bomb gas griefing.
    /// @dev Solidity's `addr.call{value: amount}("")` copies ALL returndata into memory.
    ///      A malicious recipient can exploit this by returning a large payload (e.g., 300KB)
    ///      from their receive/fallback function, causing quadratic memory expansion gas costs
    ///      charged to the caller. Using assembly with returndatasize 0 (the last two zeros in
    ///      the call opcode: `call(gas, to, amount, 0, 0, 0, 0)`) tells the EVM to skip the
    ///      returndata copy entirely, making the gas cost constant regardless of what the
    ///      recipient returns.
    /// @param _to The address to transfer ETH to
    /// @param _amount The amount of ETH to transfer in wei
    /// @return success Whether the transfer succeeded
    // slither-disable-next-line assembly
    function _safeTransferETH(address _to, uint256 _amount) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // call(gasLimit, to, value, inputOffset, inputSize, outputOffset, outputSize)
            // The final two zeros (outputOffset=0, outputSize=0) are critical:
            // they prevent the EVM from copying any returndata into memory,
            // which is what makes this immune to returndata bomb attacks.
            success := call(gas(), _to, _amount, 0, 0, 0, 0)
        }
    }
}
