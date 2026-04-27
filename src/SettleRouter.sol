// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC3009} from "./interfaces/IERC3009.sol";

/// @title  SettleRouter
/// @notice On-chain primitive for Settle. Atomically splits a customer's stablecoin
///         payment into the merchant's payout (99.5% by default) and Settle's
///         treasury fee (0.5% by default), in a single transaction.
///
/// @dev    - Uses SafeERC20 so non-standard ERC-20s like USDT (which omits the bool
///           return on transfer) work without modification.
///         - `feeBps` is hard-capped at 100 (= 1%) by `setFeeBps`. Even the owner
///           cannot set it higher, by design — protects merchants against rug.
///         - Upgradeable via UUPS. The `owner()` is intended to be a
///           `TimelockController` whose proposer/executor is a 2-of-3 Safe multisig
///           (set up at deploy time — see `script/Deploy.s.sol`).
///         - `nonReentrant` is applied to all payment paths as defense-in-depth.
///           USDC/USDT are not reentrant, but the contract accepts arbitrary
///           ERC-20s, so we don't trust the token implementation.
contract SettleRouter is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Basis-point denominator. 10_000 bps = 100%.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard cap on the fee. 100 bps = 1%. Even the owner cannot exceed this.
    uint16 public constant MAX_FEE_BPS = 100;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Address that receives the protocol fee (Settle treasury multisig).
    address public feeRecipient;

    /// @notice Current protocol fee, in basis points. Capped at `MAX_FEE_BPS`.
    uint16 public feeBps;

    /// @dev Storage gap for future upgrades. Reserves 48 slots.
    uint256[48] private __gap;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on every successful invoice payment.
    /// @param invoiceId Caller-supplied opaque invoice identifier (settle-side).
    /// @param payer     The address whose tokens were debited (the customer).
    /// @param merchant  The address that received the merchant's share.
    /// @param token     The ERC-20 token used for payment.
    /// @param amount    The total amount the customer paid (gross).
    /// @param fee       The amount routed to `feeRecipient` (already deducted from `amount`).
    event InvoicePaid(
        bytes32 indexed invoiceId,
        address indexed payer,
        address indexed merchant,
        address token,
        uint256 amount,
        uint256 fee
    );

    /// @notice Emitted when the fee recipient is rotated by the owner.
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when the fee basis-points are updated by the owner.
    event FeeBpsUpdated(uint16 oldFeeBps, uint16 newFeeBps);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error FeeBpsTooHigh(uint16 provided, uint16 max);
    error FeeBpsMismatch(uint16 expected, uint16 provided);

    // ---------------------------------------------------------------------
    // Initializer
    // ---------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy. Called once by the deployer.
    /// @param initialOwner    The owner — should be a TimelockController fronted by a multisig.
    /// @param initialFeeRecipient  Treasury address. Cannot be the zero address.
    /// @param initialFeeBps   Starting fee in bps. Must be <= MAX_FEE_BPS.
    function initialize(address initialOwner, address initialFeeRecipient, uint16 initialFeeBps)
        external
        initializer
    {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (initialFeeRecipient == address(0)) revert ZeroAddress();
        if (initialFeeBps > MAX_FEE_BPS) revert FeeBpsTooHigh(initialFeeBps, MAX_FEE_BPS);

        __Ownable_init(initialOwner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        feeRecipient = initialFeeRecipient;
        feeBps = initialFeeBps;

        emit FeeRecipientUpdated(address(0), initialFeeRecipient);
        emit FeeBpsUpdated(0, initialFeeBps);
    }

    // ---------------------------------------------------------------------
    // Payment paths
    // ---------------------------------------------------------------------

    /// @notice Pay an invoice with a token the caller has already `approve`d to this contract.
    /// @dev    The customer (msg.sender) must have called `token.approve(router, amount)` first,
    ///         OR have used one of the permit/authorization variants below.
    function payInvoice(
        bytes32 invoiceId,
        address merchant,
        address token,
        uint256 amount,
        uint16 expectedFeeBps
    ) external whenNotPaused nonReentrant {
        _payInvoice(invoiceId, msg.sender, merchant, token, amount, expectedFeeBps);
    }

    /// @notice Pay an invoice using an EIP-2612 permit. Single-tx, no prior approval.
    /// @dev    Wraps `permit(...)` in a try/catch so a front-runner who already
    ///         consumed the permit's nonce cannot grief the user — the payment
    ///         still goes through if the resulting allowance is sufficient.
    function payInvoiceWithPermit(
        bytes32 invoiceId,
        address merchant,
        address token,
        uint256 amount,
        uint16 expectedFeeBps,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused nonReentrant {
        // Try to apply the permit. If it reverts (e.g. front-run), fall through
        // and let the transferFrom below decide whether the existing allowance
        // is enough.
        try IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}

        _payInvoice(invoiceId, msg.sender, merchant, token, amount, expectedFeeBps);
    }

    /// @notice Pay an invoice using an EIP-3009 `transferWithAuthorization`.
    /// @dev    The customer signs an authorization that pulls `amount` from `from`
    ///         to this router. We then split and forward, all atomically.
    ///         `from` is required as a parameter (rather than `msg.sender`) because
    ///         the relayer submitting the tx is typically not the payer.
    function payInvoiceWithAuthorization(
        bytes32 invoiceId,
        address merchant,
        address token,
        address from,
        uint256 amount,
        uint16 expectedFeeBps,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused nonReentrant {
        _validateInputs(merchant, amount, expectedFeeBps);

        // Pull funds via 3009. The token verifies the signature, the validity
        // window, and consumes the nonce. If anything's wrong, this reverts.
        IERC3009(token).transferWithAuthorization(
            from, address(this), amount, validAfter, validBefore, nonce, v, r, s
        );

        _splitAndForward(invoiceId, from, merchant, token, amount);
    }

    // ---------------------------------------------------------------------
    // Internal payment helpers
    // ---------------------------------------------------------------------

    function _payInvoice(
        bytes32 invoiceId,
        address payer,
        address merchant,
        address token,
        uint256 amount,
        uint16 expectedFeeBps
    ) internal {
        _validateInputs(merchant, amount, expectedFeeBps);

        // Pull funds from payer. SafeERC20 handles non-standard returns (USDT).
        IERC20(token).safeTransferFrom(payer, address(this), amount);

        _splitAndForward(invoiceId, payer, merchant, token, amount);
    }

    function _validateInputs(address merchant, uint256 amount, uint16 expectedFeeBps) internal view {
        if (merchant == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (expectedFeeBps != feeBps) revert FeeBpsMismatch(feeBps, expectedFeeBps);
    }

    /// @dev Splits `amount` between `merchant` and `feeRecipient` and emits the event.
    ///      The contract should hold exactly `amount` of `token` at this point.
    function _splitAndForward(
        bytes32 invoiceId,
        address payer,
        address merchant,
        address token,
        uint256 amount
    ) internal {
        // Compute fee. Integer division truncates in our favor (merchant gets the dust).
        // No overflow: amount * MAX_FEE_BPS (=100) fits in uint256 trivially.
        uint256 fee = (amount * feeBps) / BPS_DENOMINATOR;
        uint256 merchantAmount = amount - fee;

        // Transfer to merchant first (the user-facing path), then fee. Both via SafeERC20.
        IERC20(token).safeTransfer(merchant, merchantAmount);
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
        }

        emit InvoicePaid(invoiceId, payer, merchant, token, amount, fee);
    }

    // ---------------------------------------------------------------------
    // Owner-only admin
    // ---------------------------------------------------------------------

    /// @notice Update the treasury address. Cannot be set to the zero address.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @notice Update the fee. Hard-capped at `MAX_FEE_BPS` (1%) — even the owner
    ///         cannot rug merchants by setting a higher fee.
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeBpsTooHigh(newFeeBps, MAX_FEE_BPS);
        uint16 old = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsUpdated(old, newFeeBps);
    }

    /// @notice Pause all payment paths. For security incidents only.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause payment paths.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // UUPS
    // ---------------------------------------------------------------------

    /// @dev Owner-gated. Owner is intended to be the TimelockController.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
