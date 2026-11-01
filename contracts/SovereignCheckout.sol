// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Minimal interface for TRC-20 / ERC-20 token standard.
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title SovereignCheckout
 * @notice Trustless, Non-Custodial Merchant Settlement with Deterministic Self-Refunds.
 * @dev Hardened against front-running and dust-attacker griefing via isolated per-payer refund ledgers.
 * 
 * Works identically across TVM (TRON TRC-20) and EVM (Ethereum, BSC, Arbitrum, Polygon).
 */
contract SovereignCheckout {

    enum InvoiceStatus { Active, Settled, Cancelled }

    struct Invoice {
        bytes32 invoiceId;         // Unique Merchant Order Reference (e.g., keccak256("267842472_4"))
        address merchant;          // Recipient merchant
        address boundPayer;        // Optional: Bound payer address (address(0) if open to any contributor)
        address token;             // TRC-20 / ERC-20 token address (e.g., USDT)
        uint256 expectedAmount;    // Exact required amount (in token decimals)
        uint256 totalAmountPaid;   // Cumulative amount paid across all contributors
        uint256 expiryTimestamp;   // Timestamp after which self-refund is unlocked
        InvoiceStatus status;      // Current invoice lifecycle state
    }

    // Mapping from unique invoiceId to Invoice struct
    mapping(bytes32 => Invoice) public invoices;

    // Hardened Multi-Payer Escrow Ledger: invoiceId => payerAddress => depositedAmount
    // Guarantees that each contributor can ONLY refund their own deposited funds.
    mapping(bytes32 => mapping(address => uint256)) public payerDeposits;

    // Events emitted for transparent on-chain indexing & zero-latency Web3 notifications
    event InvoiceCreated(
        bytes32 indexed invoiceId, 
        address indexed merchant, 
        address indexed boundPayer,
        address token, 
        uint256 expectedAmount, 
        uint256 expiryTimestamp
    );

    event PaymentReceived(
        bytes32 indexed invoiceId, 
        address indexed payer, 
        uint256 amount, 
        uint256 totalPaid, 
        uint256 remaining
    );

    event InvoiceSettled(
        bytes32 indexed invoiceId, 
        address indexed merchant, 
        uint256 totalAmount
    );

    event AutonomousRefundClaimed(
        bytes32 indexed invoiceId, 
        address indexed payer, 
        uint256 amountRefunded
    );

    event InvoiceCancelled(bytes32 indexed invoiceId);

    // ==========================================
    // 1. INVOICE CREATION (MERCHANT)
    // ==========================================

    /**
     * @notice Creates a new deterministic invoice.
     * @param invoiceId Unique hash representing the merchant's internal order ref.
     * @param boundPayer Optional: Specific payer address (use address(0) to allow open payments).
     * @param token Address of the payment token (e.g., USDT).
     * @param expectedAmount Exact amount required for successful settlement.
     * @param durationSeconds Time window in seconds before customers can trigger an autonomous self-refund.
     */
    function createInvoice(
        bytes32 invoiceId,
        address boundPayer,
        address token,
        uint256 expectedAmount,
        uint256 durationSeconds
    ) external {
        require(invoices[invoiceId].merchant == address(0), "Invoice ID already exists");
        require(expectedAmount > 0, "Expected amount must be greater than zero");
        require(durationSeconds >= 600, "Minimum expiry window is 10 minutes");

        invoices[invoiceId] = Invoice({
            invoiceId: invoiceId,
            merchant: msg.sender,
            boundPayer: boundPayer,
            token: token,
            expectedAmount: expectedAmount,
            totalAmountPaid: 0,
            expiryTimestamp: block.timestamp + durationSeconds,
            status: InvoiceStatus.Active
        });

        emit InvoiceCreated(
            invoiceId, 
            msg.sender, 
            boundPayer,
            token, 
            expectedAmount, 
            block.timestamp + durationSeconds
        );
    }

    // ==========================================
    // 2. PAYMENT WITH PER-PAYER ACCOUNTING
    // ==========================================

    /**
     * @notice Pay towards an active invoice. 
     * @dev Tracks deposited balances strictly per `msg.sender` to eliminate dust front-running attacks.
     *      Under NO circumstances can the merchant sweep or touch underpaid funds.
     * @param invoiceId The invoice being paid.
     * @param amount The token amount to pay.
     */
    function payInvoice(
        bytes32 invoiceId,
        uint256 amount
    ) external {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Active, "Invoice is not active");
        require(block.timestamp <= inv.expiryTimestamp, "Invoice has expired");
        require(amount > 0, "Payment amount must be greater than zero");

        // If invoice is bound to a specific payer, enforce identity
        if (inv.boundPayer != address(0)) {
            require(msg.sender == inv.boundPayer, "Caller is not authorized payer");
        }

        // Pull tokens from payer into THIS contract (NOT merchant master vault)
        bool success = IERC20(inv.token).transferFrom(msg.sender, address(this), amount);
        require(success, "Token transfer failed");

        // Record individual payer contribution in isolated ledger
        payerDeposits[invoiceId][msg.sender] += amount;
        inv.totalAmountPaid += amount;

        // CHECK 1: FULL SETTLEMENT ACHIEVED
        if (inv.totalAmountPaid >= inv.expectedAmount) {
            inv.status = InvoiceStatus.Settled;
            
            // Release funds directly to the merchant
            bool settleSuccess = IERC20(inv.token).transfer(inv.merchant, inv.totalAmountPaid);
            require(settleSuccess, "Merchant transfer failed");

            emit InvoiceSettled(invoiceId, inv.merchant, inv.totalAmountPaid);
        } else {
            // CHECK 2: PARTIAL PAYMENT / SHORTFALL
            uint256 remaining = inv.expectedAmount - inv.totalAmountPaid;
            emit PaymentReceived(invoiceId, msg.sender, amount, inv.totalAmountPaid, remaining);
        }
    }

    // ==========================================
    // 3. HARDENED AUTONOMOUS SELF-REFUND
    // ==========================================

    /**
     * @notice Autonomous, decentralized self-refund for individual contributors.
     * @dev If the invoice expired without reaching full settlement, the caller reclaims ONLY
     *      their personally deposited balance. Eliminates front-running and dust theft.
     * @param invoiceId The invoice to refund from.
     */
    function claimRefund(bytes32 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Active || inv.status == InvoiceStatus.Cancelled, "Invoice cannot be refunded");
        if (inv.status == InvoiceStatus.Active) {
            require(block.timestamp > inv.expiryTimestamp, "Invoice has not expired yet");
        }

        uint256 callerBalance = payerDeposits[invoiceId][msg.sender];
        require(callerBalance > 0, "Caller has zero deposited balance to refund");

        // Re-entrancy protection: zero balance before transfer
        payerDeposits[invoiceId][msg.sender] = 0;
        inv.totalAmountPaid -= callerBalance;

        // Execute deterministic refund directly to msg.sender
        bool refundSuccess = IERC20(inv.token).transfer(msg.sender, callerBalance);
        require(refundSuccess, "Refund transfer failed");

        emit AutonomousRefundClaimed(invoiceId, msg.sender, callerBalance);
    }

    // ==========================================
    // 4. MERCHANT EARLY CANCELLATION
    // ==========================================

    /**
     * @notice Allows the merchant to cancel an active invoice early, unlocking refunds immediately.
     * @param invoiceId The invoice to cancel.
     */
    function merchantCancel(bytes32 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.merchant, "Only merchant can cancel");
        require(inv.status == InvoiceStatus.Active, "Invoice not active");

        inv.status = InvoiceStatus.Cancelled;
        emit InvoiceCancelled(invoiceId);
    }
}
