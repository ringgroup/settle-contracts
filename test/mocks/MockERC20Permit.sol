// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice ERC-20 with EIP-2612 permit support for testing `payInvoiceWithPermit`.
contract MockERC20Permit is ERC20, ERC20Permit {
    constructor() ERC20("Mock Permit", "MPRM") ERC20Permit("Mock Permit") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
