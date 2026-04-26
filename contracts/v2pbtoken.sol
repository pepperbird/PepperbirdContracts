// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev This contract intentionally contains no fee logic, no liquidity logic,
///      and no governance logic. All future functionality is implemented in
///      separate contracts that interact with PBIRD as a standard ERC20.
//       Deploy Script PBIRDv2 v2 = new PBIRDv2(address(vault), 70_000_000_000_000 ether);

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice PBIRD v2 canonical token.
///         Name: "PBIRD"
///         Symbol: "PBIRD"
///         Permit/EIP712 version: "2"
///
///         PBIRDv1 is migrated into this token and permanently locked/removed from circulation.
///         Minting is restricted to the MigrationVault.
///         Supply is hard-capped by MAX_SUPPLY.
contract PBIRDv2 is ERC20, ERC20Permit {
    /// @notice Vault allowed to mint (the migration contract).
    address public immutable migrationVault;

    /// @notice Absolute maximum total supply PBIRDv2 can ever have.
    /// @dev Set this to the canonical PBIRDv1 supply cap (e.g. 70T * 1e18).
    uint256 public immutable MAX_SUPPLY;

    error NotMigrationVault();
    error CapExceeded();

    constructor(address _migrationVault, uint256 _maxSupply)
    ERC20("PBIRD", "PBIRD")
    ERC20Permit("PBIRD") // EIP-2612 permit (domain version handled by OZ)
    {
        migrationVault = _migrationVault;
        MAX_SUPPLY = _maxSupply;
    }

    /// @notice Mint PBIRDv2. Only MigrationVault can mint.
    function mint(address to, uint256 amount) external {
        if (msg.sender != migrationVault) revert NotMigrationVault();

        // Hard cap enforced in the token contract (final line of defense).
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();

        _mint(to, amount);
    }
}
