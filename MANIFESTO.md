# The Sovereign Payer Protocol (SPP)
## Eliminating the "Underpaid Deposit Trap" in Cryptocurrency Merchant Checkouts

**Date:** 1 November 2026  
**Authors:** Lambert Van Sittert & Antigravity  
**Repository:** `https://github.com/Lambertvs/sovereign-payer-protocol`  

---

### The Incident That Sparked This Standard:
A retail customer deposited **57.338616 USDT** via a broker checkout powered by centralized gateway **BVNK** for Order Reference `267842472_4`. Due to a $3.57 network fee deduction from the originating wallet, the amount was marginally short of the expected $64.66.

* **What the Gateway (BVNK) Did:** Swept the 57.33 USDT into its central multi-million dollar master vault (`TAZ6b1ih...`) via an automated backend bot.
* **What the Merchant (XM) Did:** Refused to credit the trading account and declared the funds *"lost due to an incorrect address not provided on our end"*.
* **The Impasse:** The gateway refused to assist the retail customer (*"We are B2B, talk to XM"*), and the broker refused to open their gateway dashboard (*"Funds are lost"*). The funds remain trapped indefinitely as unallocated float on the processor's books.

---

### How SovereignCheckout.sol Fixes This by Mathematical Law:

| Scenario | Centralized Gateway (BVNK / XM) | Sovereign Payer Protocol (SPP) |
| :--- | :--- | :--- |
| **Full Payment Received** | Funds swept to master vault, delayed webhook. | Immediate atomic settlement: Tokens transfer directly to the merchant. |
| **Underpayment / Fee Shortfall** | Gateway sweeps tokens to its master pool; webhook fails; customer funds vanish into corporate float. | **Funds stay locked inside the smart contract escrow.** The merchant and gateway **CANNOT** sweep or touch a single token. |
| **Order Expiration** | Customer is trapped begging human support agents who copy-paste canned responses. | **Autonomous Self-Refund:** Once the timer expires, the customer (or a bot) calls `claimRefund()`. The contract programmatically returns 100% of the funds to the payer's nominated wallet. |
| **Third-Party Disclaimers** | Merchant claims *"address not provided on our end"*. | **Impossible.** All invoices are immutably tied to the merchant's on-chain address and order ID on the blockchain ledger. |

---

### Verification and Compatibility:
* **TRON (TVM / TRC-20):** Solves the exact high-volume, low-fee retail trading deposit trap where TRC-20 USDT is most abused.
* **EVM Networks (Ethereum, Arbitrum, Optimism, Polygon, BSC):** Native ERC-20 compliance with zero external dependencies.
* **Zero Admin Keys:** No backdoors, no multi-sig admin seizure, no frozen accounts.
