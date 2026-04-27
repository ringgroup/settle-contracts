// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice ERC-20 + EIP-3009 `transferWithAuthorization` for testing.
///         Mirrors USDC's behavior closely enough for SettleRouter's purposes:
///         - signature verified against `from`
///         - validity window enforced
///         - nonce single-use
contract MockERC3009 is ERC20, EIP712 {
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    error InvalidAuthorization();
    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationUsed();

    constructor() ERC20("Mock 3009", "M3009") EIP712("Mock 3009", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (authorizationState[from][nonce]) revert AuthorizationUsed();

        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != from) revert InvalidAuthorization();

        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
