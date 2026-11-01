# The Sovereign Payer Protocol (SPP)
### Decentralized, Trustless Merchant Checkout & Autonomous Escrow Standard
**Authors:** Lambert Van Sittert & Antigravity (Susan)  
**Target Networks:** TRON (TVM / TRC-20), EVM (Ethereum, Arbitrum, Polygon, BSC)  
**Repository:** `https://github.com/Lambertvs/sovereign-payer-protocol`  

---

## 1. Abstract & Motivation (The Problem with Centralized Gateways)

In the current cryptocurrency commerce ecosystem, retail merchants and offshore brokers (e.g., XM) outsource their deposit and payment infrastructure to centralized third-party payment gateways (e.g., BVNK, BitPay, CoinPayments). 

These gateways instruct users to transfer tokens (such as USDT) directly to a raw, unmonitored external account (EOA). When a minor discrepancy occurs-such as network fees silently deducted by the sending exchange/wallet, resulting in an underpayment:

1. **The Sweeper Absorb:** The gateway's automated sweeper bot sweeps the incoming tokens into the processor's central master vault pool to secure corporate liquidity.
2. **The Webhook Failure:** The gateway's internal accounting marks the invoice as incomplete or `UNDERPAID` and refuses to notify the merchant.
3. **The Corporate Stonewall:** 
   - The merchant disclaims knowledge: *"You sent to an incorrect address not provided by us; funds are lost."*
   - The payment gateway refuses to deal with retail consumers: *"We are B2B; contact the merchant."*
4. **The Greed / Float Exploitation:** The underpaid or unreconciled funds remain permanently locked in the processor's corporate balance sheet as unallocated float, enriched at the direct expense of the consumer.

The **Sovereign Payer Protocol (SPP)** solves this systemic failure at the code level. It replaces raw, non-custodial address dumps with an **immutable, deterministic smart contract checkout protocol**.

---

## 2. Core Protocol Principles

1. **Atomic Invariance:** An invoice can only transition to `SETTLED` if the exact required token amount is supplied.
2. **Deterministic Reversion:** If an underpayment is attempted via direct contract call, the EVM/TVM transaction **reverts entirely at the consensus layer**, ensuring funds never leave the payer's wallet.
3. **Zero-Custody Partial Escrow:** If partial payments are allowed by the merchant parameters, the incoming tokens are locked in the smart contract escrow-**NOT in the merchant's or gateway's master vault**.
4. **Autonomous Self-Refund (No Human Support Needed):** If an invoice expires or remains unfulfilled by the merchant after a set timeout (`refundDeadline`), the payer-or any public keeper bot-can trigger `claimRefund()`. The smart contract programmatically returns 100% of the deposited tokens back to the payer's nominated refund address.
5. **No Intermediary Custody:** No CEO, no compliance officer, no tier-1 support agent, and no centralized gateway has the authority to block, seize, or withhold funds.

---

## 3. Architecture Specification

```
                                +-------------------+
                                |   Payer Wallet    |
                                +---------+---------+
                                          |
                        1. payInvoice()   |  (USDT / TRC-20 / ERC-20)
                                          v
                         +----------------------------------+
                         |     SovereignCheckout.sol        |
                         |   (Trustless Smart Contract)     |
                         +----------------+-----------------+
                                          |
                 +------------------------+------------------------+
                 |                                                 |
       [Exact / Full Payment]                             [Underpaid / Timeout]
                 |                                                 |
                 v                                                 v
   2a. Immediate Settlement                         2b. Autonomous Refund
   - Merchant receives funds                        - Merchant CANNOT sweep
   - Event: InvoiceSettled                          - After `expiry`, Payer calls:
                                                      claimRefund()
                                                    - Event: RefundProcessed
```

---

## 4. Smart Contract Reference Implementation

See [contracts/SovereignCheckout.sol](contracts/SovereignCheckout.sol) for the full open-source implementation.
