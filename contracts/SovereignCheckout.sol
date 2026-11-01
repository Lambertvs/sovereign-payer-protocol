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
 * @dev Designed specifically to replace abusive, parasitic centralized crypto gateways 
 *      (e.g., BVNK, BitPay) that swallow underpaid deposits into corporate master vaults.
 * 
 * Works identically across TVM (TRON TRC-20) and EVM (Ethereum, BSC, Arbitrum, Polygon).
 */
contract SovereignCheckout {

    enum InvoiceStatus { Active, Settled, Refunded, Cancelled }

    struct Invoice {
        bytes32 invoiceId;         // Unique Merchant Order Reference (e.g., keccak256("267842472_4"))
        address merchant;          // Recipient merchant
        address payer;             // Payer / Customer address
        address refundAddress;      // Mandatory nominated address where refunds are sent
        address token;             // TRC-20 / ERC-20 token address (e.g., USDT)
        uint256 expectedAmount;    // Exact required amount (in token decimals)
        uint256 amountPaid;        // Cumulative amount paid so far
        uint256 expiryTimestamp;   // Timestamp after which self-refund is unlocked
        InvoiceStatus status;      // Current invoice lifecycle state
    }

    // Mapping from unique invoiceId to Invoice struct
    mapping(bytes32 => Invoice) public invoices;

    // Events emitted for transparent on-chain indexing & zero-latency Web3 notifications
    event InvoiceCreated(
        bytes32 indexed invoiceId, 
        address indexed merchant, 
        address indexed token, 
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
        address indexed recipient, 
        uint256 amountRefunded
    );

    event InvoiceCancelled(bytes32 indexed invoiceId);

    // ==========================================
    // 1. INVOICE CREATION (MERCHANT)
    // ==========================================

    /**
     * @notice Creates a new deterministic invoice.
     * @param invoiceId Unique hash representing the merchant's internal order ref.
     * @param token Address of the payment token (e.g., USDT).
     * @param expectedAmount Exact amount required for successful settlement.
     * @param durationSeconds Time window in seconds before the customer can trigger an autonomous self-refund.
     */
    function createInvoice(
        bytes32 invoiceId,
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
            payer: address(0),
            refundAddress: address(0),
            token: token,
            expectedAmount: expectedAmount,
            amountPaid: 0,
            expiryTimestamp: block.timestamp + durationSeconds,
            status: InvoiceStatus.Active
        });

        emit InvoiceCreated(
            invoiceId, 
            msg.sender, 
            token, 
            expectedAmount, 
            block.timestamp + durationSeconds
        );
    }

    // ==========================================
    // 2. ATOMIC / PARTIAL PAYMENT (PAYER)
    // ==========================================

    /**
     * @notice Pay an active invoice. 
     * @dev If the amount supplied completes the invoice, it settles immediately to the merchant.
     *      If the amount is short, the funds remain safely in THIS contract's escrow.
     *      Under NO circumstances can the merchant sweep or touch underpaid funds.
     * @param invoiceId The invoice being paid.
     * @param amount The token amount to pay.
     * @param refundAddress The explicit address the payer designates for refunds.
     */
    function payInvoice(
        bytes32 invoiceId,
        uint256 amount,
        address refundAddress
    ) external {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Active, "Invoice is not active");
        require(block.timestamp <= inv.expiryTimestamp, "Invoice has expired");
        require(amount > 0, "Payment amount must be greater than zero");
        require(refundAddress != address(0), "Refund address is required");

        // First payer locks in their identity and refund address
        if (inv.payer == address(0)) {
            inv.payer = msg.sender;
            inv.refundAddress = refundAddress;
        }

        // Pull tokens from payer into THIS contract (NOT merchant master vault)
        bool success = IERC20(inv.token).transferFrom(msg.sender, address(this), amount);
        require(success, "Token transfer failed");

        inv.amountPaid += amount;

        // CHECK 1: FULL SETTLEMENT ACHIEVED
        if (inv.amountPaid >= inv.expectedAmount) {
            inv.status = InvoiceStatus.Settled;
            
            // Release funds directly to the merchant
            bool settleSuccess = IERC20(inv.token).transfer(inv.merchant, inv.amountPaid);
            require(settleSuccess, "Merchant transfer failed");

            emit InvoiceSettled(invoiceId, inv.merchant, inv.amountPaid);
        } else {
            // CHECK 2: PARTIAL PAYMENT / SHORTFALL (The BVNK Trap Solved)
            // Funds stay locked in the contract. Emits remaining amount so the payer can top-up.
            uint256 remaining = inv.expectedAmount - inv.amountPaid;
            emit PaymentReceived(invoiceId, msg.sender, amount, inv.amountPaid, remaining);
        }
    }

    // ==========================================
    // 3. AUTONOMOUS SELF-REFUND (THE BVNK KILLER)
    // ==========================================

    /**
     * @notice Autonomous, decentralized self-refund.
     * @dev If the invoice has expired without reaching full settlement, 
     *      ANYONE (the payer or a public keeper bot) can trigger this function.
     *      The contract transfers 100% of the deposited funds directly to the designated refund address.
     *      No merchant consent, no support ticket, and no gateway permission required.
     * @param invoiceId The invoice to refund.
     */
    function claimRefund(bytes32 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.Active, "Invoice cannot be refunded");
        require(block.timestamp > inv.expiryTimestamp, "Invoice has not expired yet");
        require(inv.amountPaid > 0, "No funds deposited to refund");

        uint256 refundAmount = inv.amountPaid;
        address targetAddress = inv.refundAddress != address(0) ? inv.refundAddress : inv.payer;

        // Update state to prevent re-entrancy
        inv.status = InvoiceStatus.Refunded;
        inv.amountPaid = 0;

        // Execute deterministic refund
        bool refundSuccess = IERC20(inv.token).transfer(targetAddress, refundAmount);
        require(refundSuccess, "Refund transfer failed");

        emit AutonomousRefundClaimed(invoiceId, targetAddress, refundAmount);
    }

    // ==========================================
    // 4. MERCHANT VOLUNTARY CANCELLATION / REFUND
    // ==========================================

    /**
     * @notice Allows the merchant to proactively cancel and return funds before expiry.
     * @param invoiceId The invoice to cancel.
     */
    function merchantCancelAndRefund(bytes32 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.merchant, "Only merchant can cancel early");
        require(inv.status == InvoiceStatus.Active, "Invoice not active");

        inv.status = InvoiceStatus.Cancelled;

        if (inv.amountPaid > 0) {
            uint256 refundAmount = inv.amountPaid;
            address targetAddress = inv.refundAddress != address(0) ? inv.refundAddress : inv.payer;
            inv.amountPaid = 0;

            bool refundSuccess = IERC20(inv.token).transfer(targetAddress, refundAmount);
            require(refundSuccess, "Refund transfer failed");

            emit AutonomousRefundClaimed(invoiceId, targetAddress, refundAmount);
        } else {
            emit InvoiceCancelled(invoiceId);
        }
    }
}
