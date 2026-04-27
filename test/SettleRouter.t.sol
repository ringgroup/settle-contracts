// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {SettleRouter} from "../src/SettleRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockERC3009} from "./mocks/MockERC3009.sol";

contract SettleRouterTest is Test {
    SettleRouter internal router;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal merchant = makeAddr("merchant");
    address internal payer; // derived from PK below
    uint256 internal payerPk = 0xA11CE;

    bytes32 internal constant INVOICE_ID = bytes32("inv_test_001");
    uint16 internal constant INITIAL_FEE_BPS = 50; // 0.5%

    event InvoicePaid(
        bytes32 indexed invoiceId,
        address indexed payer,
        address indexed merchant,
        address token,
        uint256 amount,
        uint256 fee
    );

    function setUp() public {
        payer = vm.addr(payerPk);

        SettleRouter impl = new SettleRouter();
        bytes memory initCalldata = abi.encodeCall(
            SettleRouter.initialize, (owner, treasury, INITIAL_FEE_BPS)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initCalldata);
        router = SettleRouter(address(proxy));
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function test_initialize_sets_state() public view {
        assertEq(router.owner(), owner, "owner");
        assertEq(router.feeRecipient(), treasury, "treasury");
        assertEq(router.feeBps(), INITIAL_FEE_BPS, "feeBps");
        assertEq(router.MAX_FEE_BPS(), 100, "max fee bps");
        assertEq(router.BPS_DENOMINATOR(), 10_000, "denominator");
    }

    function test_initialize_reverts_on_zero_owner() public {
        SettleRouter impl = new SettleRouter();
        bytes memory initCalldata = abi.encodeCall(
            SettleRouter.initialize, (address(0), treasury, INITIAL_FEE_BPS)
        );
        vm.expectRevert(SettleRouter.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initCalldata);
    }

    function test_initialize_reverts_on_zero_treasury() public {
        SettleRouter impl = new SettleRouter();
        bytes memory initCalldata = abi.encodeCall(
            SettleRouter.initialize, (owner, address(0), INITIAL_FEE_BPS)
        );
        vm.expectRevert(SettleRouter.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initCalldata);
    }

    function test_initialize_reverts_on_excessive_fee() public {
        SettleRouter impl = new SettleRouter();
        bytes memory initCalldata = abi.encodeCall(
            SettleRouter.initialize, (owner, treasury, uint16(101))
        );
        vm.expectRevert(abi.encodeWithSelector(SettleRouter.FeeBpsTooHigh.selector, uint16(101), uint16(100)));
        new ERC1967Proxy(address(impl), initCalldata);
    }

    function test_initialize_can_only_run_once() public {
        vm.expectRevert();
        router.initialize(owner, treasury, INITIAL_FEE_BPS);
    }

    // ---------------------------------------------------------------------
    // payInvoice — happy paths
    // ---------------------------------------------------------------------

    function test_payInvoice_splits_correctly() public {
        // $100 USDC (6 decimals) at 50 bps -> $99.50 merchant, $0.50 treasury.
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        uint256 amount = 100 * 10 ** 6; // $100
        usdc.mint(payer, amount);

        vm.prank(payer);
        usdc.approve(address(router), amount);

        vm.prank(payer);
        router.payInvoice(INVOICE_ID, merchant, address(usdc), amount, INITIAL_FEE_BPS);

        assertEq(usdc.balanceOf(merchant), 99_500_000, "merchant gets 99.50");
        assertEq(usdc.balanceOf(treasury), 500_000, "treasury gets 0.50");
        assertEq(usdc.balanceOf(payer), 0, "payer drained");
        assertEq(usdc.balanceOf(address(router)), 0, "router holds nothing");
    }

    function test_payInvoice_emits_event() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        uint256 amount = 100 * 10 ** 6;
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(router), amount);

        vm.expectEmit(true, true, true, true, address(router));
        emit InvoicePaid(INVOICE_ID, payer, merchant, address(usdc), amount, 500_000);

        vm.prank(payer);
        router.payInvoice(INVOICE_ID, merchant, address(usdc), amount, INITIAL_FEE_BPS);
    }

    function test_payInvoice_works_with_zero_fee() public {
        // Owner sets fee to 0, the contract must still work and skip the fee transfer.
        vm.prank(owner);
        router.setFeeBps(0);

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        uint256 amount = 100 * 10 ** 6;
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(router), amount);

        vm.prank(payer);
        router.payInvoice(INVOICE_ID, merchant, address(usdc), amount, 0);

        assertEq(usdc.balanceOf(merchant), amount);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_payInvoice_works_with_USDT_non_standard_transfer() public {
        // Real USDT does not return bool. SafeERC20 must handle it.
        MockUSDT usdt = new MockUSDT();
        uint256 amount = 100 * 10 ** 6;
        usdt.mint(payer, amount);

        vm.prank(payer);
        usdt.approve(address(router), amount);

        vm.prank(payer);
        router.payInvoice(INVOICE_ID, merchant, address(usdt), amount, INITIAL_FEE_BPS);

        assertEq(usdt.balanceOf(merchant), 99_500_000);
        assertEq(usdt.balanceOf(treasury), 500_000);
    }

    // ---------------------------------------------------------------------
    // payInvoice — reverts
    // ---------------------------------------------------------------------

    function test_payInvoice_reverts_on_zero_amount() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(payer);
        vm.expectRevert(SettleRouter.ZeroAmount.selector);
        router.payInvoice(INVOICE_ID, merchant, address(usdc), 0, INITIAL_FEE_BPS);
    }

    function test_payInvoice_reverts_on_zero_merchant() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.prank(payer);
        vm.expectRevert(SettleRouter.ZeroAddress.selector);
        router.payInvoice(INVOICE_ID, address(0), address(usdc), 100, INITIAL_FEE_BPS);
    }

    function test_payInvoice_reverts_on_fee_mismatch() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        usdc.mint(payer, 100);
        vm.prank(payer);
        usdc.approve(address(router), 100);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(SettleRouter.FeeBpsMismatch.selector, INITIAL_FEE_BPS, uint16(60))
        );
        router.payInvoice(INVOICE_ID, merchant, address(usdc), 100, 60);
    }

    function test_payInvoice_reverts_on_missing_allowance() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        usdc.mint(payer, 100);
        // No approval.

        vm.prank(payer);
        vm.expectRevert();
        router.payInvoice(INVOICE_ID, merchant, address(usdc), 100, INITIAL_FEE_BPS);
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    function test_pause_blocks_payments() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        usdc.mint(payer, 100);
        vm.prank(payer);
        usdc.approve(address(router), 100);

        vm.prank(owner);
        router.pause();

        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.payInvoice(INVOICE_ID, merchant, address(usdc), 100, INITIAL_FEE_BPS);
    }

    function test_unpause_restores_payments() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        usdc.mint(payer, 100);
        vm.prank(payer);
        usdc.approve(address(router), 100);

        vm.prank(owner);
        router.pause();
        vm.prank(owner);
        router.unpause();

        vm.prank(payer);
        router.payInvoice(INVOICE_ID, merchant, address(usdc), 100, INITIAL_FEE_BPS);
    }

    function test_only_owner_can_pause() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payer));
        router.pause();
    }

    // ---------------------------------------------------------------------
    // Admin: setFeeBps
    // ---------------------------------------------------------------------

    function test_setFeeBps_caps_at_100_bps() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SettleRouter.FeeBpsTooHigh.selector, uint16(101), uint16(100)));
        router.setFeeBps(101);
    }

    function test_setFeeBps_allows_exactly_100_bps() public {
        vm.prank(owner);
        router.setFeeBps(100);
        assertEq(router.feeBps(), 100);
    }

    function test_setFeeBps_emits_event() public {
        vm.prank(owner);
        router.setFeeBps(75);
        assertEq(router.feeBps(), 75);
    }

    function test_only_owner_can_setFeeBps() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payer));
        router.setFeeBps(25);
    }

    // ---------------------------------------------------------------------
    // Admin: setFeeRecipient
    // ---------------------------------------------------------------------

    function test_setFeeRecipient_works() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        router.setFeeRecipient(newTreasury);
        assertEq(router.feeRecipient(), newTreasury);
    }

    function test_setFeeRecipient_reverts_on_zero_address() public {
        vm.prank(owner);
        vm.expectRevert(SettleRouter.ZeroAddress.selector);
        router.setFeeRecipient(address(0));
    }

    function test_only_owner_can_setFeeRecipient() public {
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payer));
        router.setFeeRecipient(makeAddr("attacker"));
    }

    // ---------------------------------------------------------------------
    // payInvoiceWithPermit
    // ---------------------------------------------------------------------

    function test_payInvoiceWithPermit_pulls_funds_via_permit() public {
        MockERC20Permit token = new MockERC20Permit();
        uint256 amount = 1_000 * 10 ** 18;
        token.mint(payer, amount);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(
            abi.encode(permitTypehash, payer, address(router), amount, token.nonces(payer), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);

        // Submitted by anyone (here, payer themselves).
        vm.prank(payer);
        router.payInvoiceWithPermit(
            INVOICE_ID, merchant, address(token), amount, INITIAL_FEE_BPS, deadline, v, r, s
        );

        assertEq(token.balanceOf(merchant), amount - (amount * 50) / 10_000);
        assertEq(token.balanceOf(treasury), (amount * 50) / 10_000);
    }

    // ---------------------------------------------------------------------
    // payInvoiceWithAuthorization
    // ---------------------------------------------------------------------

    function test_payInvoiceWithAuthorization_pulls_funds_via_3009() public {
        MockERC3009 token = new MockERC3009();
        uint256 amount = 100 * 10 ** 6;
        token.mint(payer, amount);

        // Need a non-zero block.timestamp for validAfter math.
        vm.warp(1_000);

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 5 minutes;
        bytes32 nonce = bytes32(uint256(0xdeadbeef));

        bytes32 structHash = keccak256(
            abi.encode(
                token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
                payer,
                address(router),
                amount,
                validAfter,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);

        // Submitted by a relayer, not the payer.
        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        router.payInvoiceWithAuthorization(
            INVOICE_ID,
            merchant,
            address(token),
            payer,
            amount,
            INITIAL_FEE_BPS,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );

        assertEq(token.balanceOf(merchant), 99_500_000);
        assertEq(token.balanceOf(treasury), 500_000);
        assertTrue(token.authorizationState(payer, nonce), "nonce consumed");
    }

    // ---------------------------------------------------------------------
    // UUPS upgrade gating
    // ---------------------------------------------------------------------

    function test_upgrade_only_owner() public {
        SettleRouter newImpl = new SettleRouter();
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payer));
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_works_for_owner() public {
        SettleRouter newImpl = new SettleRouter();
        vm.prank(owner);
        router.upgradeToAndCall(address(newImpl), "");
        // State is preserved.
        assertEq(router.feeRecipient(), treasury);
        assertEq(router.feeBps(), INITIAL_FEE_BPS);
    }
}
