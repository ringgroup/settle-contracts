// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Mimics real USDT on Ethereum: `transfer` and `transferFrom` do NOT
///         return a bool. Calling `IERC20(usdt).transfer(...)` against this
///         contract via the standard ERC-20 ABI fails the standard return-value
///         check — which is why `SafeERC20` exists.
///
///         This mock is intentionally minimal: just enough to verify SettleRouter
///         works against tokens that violate the spec.
contract MockUSDT {
    string public constant name = "Mock USDT";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Approve `spender` for `amount`. Returns nothing — like real USDT.
    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    /// @notice Transfer `amount` to `to`. Returns nothing — like real USDT.
    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    /// @notice transferFrom — also returns nothing.
    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "USDT: insufficient allowance");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "USDT: insufficient balance");
        unchecked {
            balanceOf[from] -= amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
