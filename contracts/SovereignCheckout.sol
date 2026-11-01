// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Low-level safe token transfer library handling non-standard ERC-20 implementations (e.g. mainnet USDT
 *      which does not return a boolean) and reverts with clear errors.
 */
library SafeTransferLib {
    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransfer: failed");
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransferFrom: failed");
    }

    function getBalance(address token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(0x70a08231, account)
        );
        require(success && data.length >= 32, "GetBalance: failed");
        return abi.decode(data, (uint256));
    }
}

/**
 * @title SovereignCheckout
 * @notice Trustless, Non-Custodial Merchant Settlement with Deterministic Self-Refunds.
 * @dev Hardened against:
 *      1. Front-running / invoice squatting by scoping invoices to keccak256(merchant, invoiceId).
 *      2. Non-standard ERC-20 tokens (e.g., mainnet USDT missing return boolean).
 *      3. Fee-on-transfer discrepancies via strict pre/post balance differential accounting.
 *      4. Dust-attacker front-running via isolated per-payer refund ledgers.
 *      5. Permissionless keeper refunds (claimRefundFor) while strictly enforcing authorized refund destinations.
 */
contract SovereignCheckout {
    using SafeTransferLib for address;

    enum InvoiceStatus { Active, Settled, Cancelled }

    struct Invoice {
        address merchant;          // Recipient merchant
        address boundPayer;        // Optional: Specific bound payer (address(0) if open)
        address token;             // Payment token (e.g., USDT)
        uint256 expectedAmount;    // Exact required amount (in token decimals)
        uint256 totalAmountPaid;   // Cumulative net tokens received across all contributors
        uint256 expiryTimestamp;   // Timestamp after which refunds unlock
        InvoiceStatus status;      // Current invoice lifecycle state
    }

    struct PayerRecord {
        uint256 amountDeposited;   // Net balance available for refund
        address refundAddress;     // Authorized destination address for this payer
    }

    // Mapping from computed invoiceKey (keccak256(merchant, invoiceId)) to Invoice
    mapping(bytes32 => Invoice) public invoices;

    // Hardened Isolated Escrow Ledger: invoiceKey => payerAddress => PayerRecord
    mapping(bytes32 => mapping(address => PayerRecord)) public payerRecords;

    // Events emitted for transparent on-chain indexing
    event InvoiceCreated(
        bytes32 indexed invoiceKey,
        address indexed merchant,
        bytes32 indexed invoiceId,
        address boundPayer,
        address token,
        uint256 expectedAmount,
        uint256 expiryTimestamp
    );

    event PaymentReceived(
        bytes32 indexed invoiceKey,
        address indexed payer,
        address indexed refundAddress,
        uint256 netAmountReceived,
        uint256 totalPaid,
        uint256 remaining
    );

    event InvoiceSettled(
        bytes32 indexed invoiceKey,
        address indexed merchant,
        uint256 totalAmount
    );

    event AutonomousRefundClaimed(
        bytes32 indexed invoiceKey,
        address indexed payer,
        address indexed recipient,
        uint256 amountRefunded,
        address triggeredBy
    );

    event InvoiceCancelled(bytes32 indexed invoiceKey);

    /**
     * @notice Computes the immutable unique key for an invoice scoped to a specific merchant.
     * @dev Eliminates front-running, squatting, and cross-merchant collision.
     */
    function getInvoiceKey(address merchant, bytes32 invoiceId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(merchant, invoiceId));
    }

    // ==========================================
    // 1. INVOICE CREATION (MERCHANT)
    // ==========================================

    function createInvoice(
        bytes32 invoiceId,
        address boundPayer,
        address token,
        uint256 expectedAmount,
        uint256 durationSeconds
    ) external returns (bytes32 invoiceKey) {
        invoiceKey = getInvoiceKey(msg.sender, invoiceId);
        require(invoices[invoiceKey].merchant == address(0), "Invoice already exists for merchant");
        require(expectedAmount > 0, "Expected amount must be greater than zero");
        require(durationSeconds >= 600, "Minimum expiry window is 10 minutes");

        invoices[invoiceKey] = Invoice({
            merchant: msg.sender,
            boundPayer: boundPayer,
            token: token,
            expectedAmount: expectedAmount,
            totalAmountPaid: 0,
            expiryTimestamp: block.timestamp + durationSeconds,
            status: InvoiceStatus.Active
        });

        emit InvoiceCreated(
            invoiceKey,
            msg.sender,
            invoiceId,
            boundPayer,
            token,
            expectedAmount,
            block.timestamp + durationSeconds
        );
    }

    // ==========================================
    // 2. PAYMENT WITH SQUATTING & USDT DEFENSES
    // ==========================================

    /**
     * @notice Pay towards an active invoice. 
     * @dev Scoped by (merchant, invoiceId) to prevent merchant-squatting. Uses balance differential
     *      to guarantee exact net tokens received (safeguarding against fee-on-transfer tokens) and
     *      SafeTransferLib to support non-standard tokens like mainnet USDT.
     * @param merchant The recipient merchant address.
     * @param invoiceId The unique merchant order ID.
     * @param amount The token amount to transfer.
     * @param refundAddress Explicit authorized destination for refunds (defaults to msg.sender if zero).
     */
    function payInvoice(
        address merchant,
        bytes32 invoiceId,
        uint256 amount,
        address refundAddress
    ) external {
        bytes32 invoiceKey = getInvoiceKey(merchant, invoiceId);
        Invoice storage inv = invoices[invoiceKey];

        require(inv.status == InvoiceStatus.Active, "Invoice is not active");
        require(block.timestamp <= inv.expiryTimestamp, "Invoice has expired");
        require(amount > 0, "Payment amount must be greater than zero");

        if (inv.boundPayer != address(0)) {
            require(msg.sender == inv.boundPayer, "Caller is not authorized payer");
        }

        address designatedRefund = (refundAddress != address(0)) ? refundAddress : msg.sender;

        // Measure actual net tokens received to prevent fee-on-transfer under-collateralization
        uint256 balanceBefore = inv.token.getBalance(address(this));
        inv.token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = inv.token.getBalance(address(this));
        uint256 netReceived = balanceAfter - balanceBefore;
        require(netReceived > 0, "Zero tokens received");

        PayerRecord storage record = payerRecords[invoiceKey][msg.sender];
        record.amountDeposited += netReceived;
        record.refundAddress = designatedRefund;

        inv.totalAmountPaid += netReceived;

        if (inv.totalAmountPaid >= inv.expectedAmount) {
            inv.status = InvoiceStatus.Settled;
            
            inv.token.safeTransfer(inv.merchant, inv.totalAmountPaid);
            emit InvoiceSettled(invoiceKey, inv.merchant, inv.totalAmountPaid);
        } else {
            uint256 remaining = inv.expectedAmount - inv.totalAmountPaid;
            emit PaymentReceived(invoiceKey, msg.sender, designatedRefund, netReceived, inv.totalAmountPaid, remaining);
        }
    }

    // ==========================================
    // 3. PERMISSIONLESS KEEPER-COMPATIBLE REFUND
    // ==========================================

    /**
     * @notice Permissionless refund for a specified payer.
     * @dev ANYONE (keeper bot, merchant, or user) can call this once expired or cancelled.
     *      Funds are strictly routed to the authorized `refundAddress` registered by that payer.
     *      Sequential claims by multiple contributors are preserved independently.
     */
    function claimRefundFor(address merchant, bytes32 invoiceId, address payer) public {
        bytes32 invoiceKey = getInvoiceKey(merchant, invoiceId);
        Invoice storage inv = invoices[invoiceKey];

        require(inv.status == InvoiceStatus.Active || inv.status == InvoiceStatus.Cancelled, "Invoice cannot be refunded");
        if (inv.status == InvoiceStatus.Active) {
            require(block.timestamp > inv.expiryTimestamp, "Invoice has not expired yet");
        }

        PayerRecord storage record = payerRecords[invoiceKey][payer];
        uint256 claimable = record.amountDeposited;
        require(claimable > 0, "No refundable balance for specified payer");

        address destination = record.refundAddress;
        require(destination != address(0), "Invalid refund address");

        // Checks-Effects-Interactions: zero out balance before transfer
        record.amountDeposited = 0;
        inv.totalAmountPaid -= claimable;

        inv.token.safeTransfer(destination, claimable);

        emit AutonomousRefundClaimed(invoiceKey, payer, destination, claimable, msg.sender);
    }

    /**
     * @notice Convenience self-refund for callers reclaiming their own funds.
     */
    function claimRefund(address merchant, bytes32 invoiceId) external {
        claimRefundFor(merchant, invoiceId, msg.sender);
    }

    // ==========================================
    // 4. MERCHANT EARLY CANCELLATION
    // ==========================================

    function merchantCancel(bytes32 invoiceId) external {
        bytes32 invoiceKey = getInvoiceKey(msg.sender, invoiceId);
        Invoice storage inv = invoices[invoiceKey];

        require(inv.merchant == msg.sender, "Only merchant can cancel");
        require(inv.status == InvoiceStatus.Active, "Invoice not active");

        inv.status = InvoiceStatus.Cancelled;
        emit InvoiceCancelled(invoiceKey);
    }
}
