// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SettleRouter} from "../src/SettleRouter.sol";

/// @title Deploy
/// @notice Deploys the SettleRouter UUPS proxy.
///
/// @dev Production setup (NOT done by this script):
///         1. Deploy a Gnosis Safe (2-of-3 — founder, cofounder, cold backup).
///         2. Deploy an OpenZeppelin TimelockController with:
///              - minDelay = 48 hours
///              - proposers = [Safe]
///              - executors = [Safe]   (or address(0) for "anyone can execute" once delay elapses)
///              - admin     = address(0)  (renounce)
///         3. Run THIS script with `OWNER=<TimelockController address>` and
///            `FEE_RECIPIENT=<Treasury Safe address>`.
///         4. The router proxy's `owner()` is then the Timelock; admin actions
///            require Safe → schedule → wait 48h → execute.
///
///       For testnet (Base Sepolia) you can pass an EOA as both OWNER and
///       FEE_RECIPIENT to keep iteration fast.
///
/// Required env vars:
///   PRIVATE_KEY      — deployer key (testnet: a fresh key with Sepolia ETH)
///   OWNER            — address that will own the router (timelock on mainnet, EOA on testnet)
///   FEE_RECIPIENT    — treasury address
///   INITIAL_FEE_BPS  — optional, defaults to 50 (= 0.5%). Capped at 100 by the contract.
contract Deploy is Script {
    function run() external returns (address proxy, address implementation) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address ownerAddr = vm.envAddress("OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint16 initialFeeBps = uint16(vm.envOr("INITIAL_FEE_BPS", uint256(50)));

        vm.startBroadcast(deployerKey);

        // 1. Deploy implementation.
        SettleRouter impl = new SettleRouter();

        // 2. Deploy proxy + initialize atomically.
        bytes memory initCalldata = abi.encodeCall(
            SettleRouter.initialize, (ownerAddr, feeRecipient, initialFeeBps)
        );
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(impl), initCalldata);

        vm.stopBroadcast();

        proxy = address(proxyContract);
        implementation = address(impl);

        console2.log("==========================================");
        console2.log("SettleRouter deployed");
        console2.log("==========================================");
        console2.log("Proxy (use this address):  ", proxy);
        console2.log("Implementation:            ", implementation);
        console2.log("Owner:                     ", ownerAddr);
        console2.log("Fee recipient (treasury):  ", feeRecipient);
        console2.log("Initial fee (bps):         ", initialFeeBps);
        console2.log("==========================================");
    }
}
