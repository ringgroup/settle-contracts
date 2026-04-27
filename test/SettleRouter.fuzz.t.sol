// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SettleRouter} from "../src/SettleRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Property-based fuzz tests for the split invariant and decimal robustness.
contract SettleRouterFuzzTest is Test {
    SettleRouter internal router;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal merchant = makeAddr("merchant");
    address internal payer = makeAddr("payer");

    function setUp() public {
        SettleRouter impl = new SettleRouter();
        bytes memory initCalldata = abi.encodeCall(SettleRouter.initialize, (owner, treasury, uint16(50)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initCalldata);
        router = SettleRouter(address(proxy));
    }

    /// @notice Invariant: `merchantReceived + treasuryReceived == amount` for any
    ///         (amount, feeBps) in the legal range. No tokens are lost or printed.
    function testFuzz_splitConservesValue(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 1e30); // up to 10^30 base units — generous
        feeBps = uint16(bound(uint256(feeBps), 0, 100));

        // Owner adjusts the fee.
        vm.prank(owner);
        router.setFeeBps(feeBps);

        MockERC20 token = new MockERC20("USD Coin", "USDC", 6);
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);

        vm.prank(payer);
        router.payInvoice(bytes32("inv"), merchant, address(token), amount, feeBps);

        uint256 m = token.balanceOf(merchant);
        uint256 t = token.balanceOf(treasury);
        assertEq(m + t, amount, "value conserved");
        assertEq(token.balanceOf(address(router)), 0, "router holds zero");
        // Treasury never gets more than the fee implies (rounded down).
        assertLe(t, (amount * feeBps) / 10_000);
    }

    /// @notice Decimal-robustness: any decimals from 0..30 settle the same way.
    function testFuzz_anyDecimals(uint8 decimals, uint128 amount) public {
        decimals = uint8(bound(uint256(decimals), 0, 30));
        vm.assume(amount > 0);

        MockERC20 token = new MockERC20("Test", "TST", decimals);
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);

        vm.prank(payer);
        router.payInvoice(bytes32("inv"), merchant, address(token), amount, uint16(50));

        uint256 fee = (uint256(amount) * 50) / 10_000;
        assertEq(token.balanceOf(treasury), fee);
        assertEq(token.balanceOf(merchant), uint256(amount) - fee);
        assertEq(token.balanceOf(address(router)), 0);
    }

    /// @notice Multiple sequential payments don't leak balance into the router.
    function testFuzz_routerHoldsZeroAfterMultiplePayments(uint8 n, uint128 amountPer) public {
        n = uint8(bound(uint256(n), 1, 20));
        vm.assume(amountPer > 0);

        MockERC20 token = new MockERC20("USDC", "USDC", 6);
        uint256 total = uint256(amountPer) * n;
        token.mint(payer, total);
        vm.prank(payer);
        token.approve(address(router), total);

        for (uint256 i = 0; i < n; i++) {
            vm.prank(payer);
            router.payInvoice(bytes32(i), merchant, address(token), amountPer, uint16(50));
        }

        assertEq(token.balanceOf(address(router)), 0, "router never accumulates");
        assertEq(token.balanceOf(merchant) + token.balanceOf(treasury), total, "total conserved");
    }

    /// @notice setFeeBps fuzz: any value > 100 must revert; any value <= 100 must succeed.
    function testFuzz_setFeeBpsCap(uint16 newBps) public {
        vm.prank(owner);
        if (newBps > 100) {
            vm.expectRevert(
                abi.encodeWithSelector(SettleRouter.FeeBpsTooHigh.selector, newBps, uint16(100))
            );
            router.setFeeBps(newBps);
        } else {
            router.setFeeBps(newBps);
            assertEq(router.feeBps(), newBps);
        }
    }
}
