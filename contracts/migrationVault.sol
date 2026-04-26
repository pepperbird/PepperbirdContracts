
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IERC20PermitLike {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IPBIRDv2Mint {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function MAX_SUPPLY() external view returns (uint256);
}

contract MigrationVault {
    IERC20Like public immutable pbirdV1;

    IPBIRDv2Mint public pbirdV2; // set once
    bool public v2Set;

    address public immutable owner;
    bool public paused;
    bool public migrationClosed; // Flags when the migration window is permanently over

    /// @notice Tracks total PBIRDv1 actually received (net of any transfer taxes).
    uint256 public totalMigrated;

    error ZeroAmount();
    error TransferFailed();
    error V2AlreadySet();
    error V2NotSet();
    error NotOwner();
    error Paused();
    error CapExceeded();
    error PermitNotSupported();
    error NoTokensReceived();
    error MigrationEnded();
    error CannotRescueV1();

    event V2Set(address indexed pbirdV2);
    event Migrated(address indexed user, uint256 amountIn, uint256 amountReceived);
    event PausedSet(bool paused);
    event MigrationClosed();

    constructor(address _pbirdV1, address _owner) {
        pbirdV1 = IERC20Like(_pbirdV1);
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier notPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier migrationActive() {
        if (migrationClosed) revert MigrationEnded();
        _;
    }

    /// @notice One-time wiring of PBIRDv2 contract. Restricted to owner to prevent malicious front-running.
    function setPBIRDv2Once(address _pbirdV2) external onlyOwner {
        if (v2Set) revert V2AlreadySet();
        pbirdV2 = IPBIRDv2Mint(_pbirdV2);
        v2Set = true;
        emit V2Set(_pbirdV2);
    }

    /// @notice Emergency stop for migration (safety only). Does not affect PBIRDv2 transfers.
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Permanently ends the migration period. Once called, no further migrations can occur.
    function finishMigration() external onlyOwner {
        if (migrationClosed) revert MigrationEnded();
        migrationClosed = true;
        emit MigrationClosed();
    }

    /// @notice Allows the owner to rescue accidentally sent tokens.
    /// @dev Explicitly blocks the rescue of PBIRDv1 to maintain the permanent lock invariant.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(pbirdV1)) revert CannotRescueV1();

        bool ok = IERC20Like(token).transfer(to, amount);
        if (!ok) revert TransferFailed();
    }

    // -------------------------
    // Canonical migration entry
    // -------------------------

    /// @notice Migrate PBIRDv1 -> PBIRDv2 (mints based on actual received, safe for fee-on-transfer).
    function migrate(uint256 amount) external notPaused migrationActive {
        _migrate(msg.sender, amount);
    }

    /// @notice Migrate the user's entire PBIRDv1 balance in one transaction to avoid dust.
    function migrateAll() external notPaused migrationActive {
        uint256 amount = pbirdV1.balanceOf(msg.sender);
        _migrate(msg.sender, amount);
    }

    /// @notice Convenience: approve via permit then migrate in a single transaction.
    /// @dev Only works if PBIRDv1 supports EIP-2612 permit.
    function migrateWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external notPaused migrationActive {
        _migrateWithPermit(msg.sender, amount, deadline, v, r, s);
    }

    // -------------------------
    // Wallet-friendly aliases
    // -------------------------

    function migratePbirdV1ToV2(uint256 amount) external notPaused migrationActive {
        _migrate(msg.sender, amount);
    }

    function migratePbirdV1ToV2WithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external notPaused migrationActive {
        _migrateWithPermit(msg.sender, amount, deadline, v, r, s);
    }

    // -------------------------
    // UX & Transparency Views
    // -------------------------

    /// @notice Returns global migration statistics for frontend transparency.
    function getMigrationStats() external view returns (uint256 migrated, uint256 v1VaultBalance, uint256 v2Supply) {
        migrated = totalMigrated;
        v1VaultBalance = pbirdV1.balanceOf(address(this));
        v2Supply = v2Set ? pbirdV2.totalSupply() : 0;
    }

    /// @notice Returns specific user metrics to optimize UI loading flows.
    function checkStatus(address user) external view returns (uint256 balance, uint256 allowance) {
        balance = pbirdV1.balanceOf(user);
        allowance = pbirdV1.allowance(user, address(this));
    }

    // -------------------------
    // Internal shared logic
    // -------------------------

    function _migrate(address user, uint256 amount) internal {
        if (!v2Set) revert V2NotSet();
        if (amount == 0) revert ZeroAmount();

        // Measure actual received to support fee-on-transfer PBIRDv1.
        uint256 balBefore = pbirdV1.balanceOf(address(this));

        bool ok = pbirdV1.transferFrom(user, address(this), amount);
        if (!ok) revert TransferFailed();

        uint256 balAfter = pbirdV1.balanceOf(address(this));
        uint256 received = balAfter - balBefore;
        if (received == 0) revert NoTokensReceived();

        // Cap check MUST be on received, not requested amount
        if (pbirdV2.totalSupply() + received > pbirdV2.MAX_SUPPLY()) revert CapExceeded();

        totalMigrated += received;
        pbirdV2.mint(user, received);

        emit Migrated(user, amount, received);
    }

    function _migrateWithPermit(
        address user,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        if (!v2Set) revert V2NotSet();
        if (amount == 0) revert ZeroAmount();

        // [SEC-03 Mitigation]: Check if allowance is already sufficient (e.g., if front-run)
        if (pbirdV1.allowance(user, address(this)) < amount) {
            // If PBIRDv1 doesn't implement permit, this call will revert with a low-level error.
            (bool success, bytes memory data) = address(pbirdV1).call(
                abi.encodeWithSelector(
                    IERC20PermitLike.permit.selector,
                    user,
                    address(this),
                    amount,
                    deadline,
                    v, r, s
                )
            );

            if (!success) {
                // Bubble up revert data (e.g. expired, invalid signature)
                if (data.length > 0) {
                    assembly {
                        revert(add(data, 0x20), mload(data))
                    }
                }
                // No data: treat as "permit not supported"
                revert PermitNotSupported();
            }
        }

        // Pass execution to the standard migration logic to stay DRY
        _migrate(user, amount);
    }

    // Intentionally NO withdraw function: PBIRDv1 is permanently locked once deposited.
}
