# TickVault Smart Contract

TickVault is a Clarity smart contract for locking STX or fungible tokens for a fixed period, earning rewards based on lock duration. It includes admin controls, emergency features, and safe arithmetic operations.

---

## Features

- **Lock STX or tokens** for a set duration (1 day to 1 year)
- **Earn bonus rewards** based on lock duration and tier
- **Withdraw funds** after unlock, fully or partially
- **Admin controls** for pausing, emergency mode, and tier management
- **Beneficiary system** for sharing vault benefits
- **Safe arithmetic** and strict validation for security
- **User statistics** tracking for locks and withdrawals
- **Token vault support** for any SIP-010 compliant token

---

## Data Structures

- **Vaults:** Store locked STX per user
- **Token Vaults:** Store locked tokens per user and token contract
- **Tier Rewards:** Map lock durations to bonus rates
- **Beneficiaries:** Up to 5 beneficiaries per user with share percentages
- **Delegates:** Up to 10 delegates per user
- **User Stats:** Track total locked, withdrawn, and lock count

---

## Main Functions

### Public Functions

#### STX Operations
- `lock-funds(amount, unlock-height)`  
  Lock STX for a period, earning a bonus.
- `withdraw()`  
  Withdraw all unlocked STX (with bonus).
- `partial-withdraw(withdraw-amount)`  
  Withdraw part of unlocked STX.

#### Token Operations
- `lock-token-funds(token-contract, amount, unlock-height)`  
  Lock fungible tokens for a period.
- `withdraw-tokens(token-contract)`  
  Withdraw all unlocked tokens.
- `partial-withdraw-tokens(token-contract, withdraw-amount)`  
  Withdraw part of unlocked tokens.

#### Beneficiary Management
- `add-beneficiary(beneficiary, share)`  
  Add a beneficiary with specified share percentage.
- `approve-beneficiary-status()`  
  Approve beneficiary status for self.

#### Admin Controls
- `set-contract-admin(new-admin)`  
  Change contract admin.
- `toggle-emergency-mode()`  
  Enable/disable emergency mode.
- `pause-contract()` / `unpause-contract()`  
  Pause/unpause contract operations.
- `set-tier-reward(duration, bonus-rate)`  
  Set bonus rate for a lock duration.
- `emergency-withdraw(user)`  
  Admin can withdraw user funds in emergency mode.

### Read-Only Functions
- `get-vault-info(owner)`
- `get-token-vault-info(owner, token-contract)`
- `get-user-stats(user)`
- `get-tier-reward(duration)`
- `get-contract-admin()`
- `get-emergency-mode()`
- `get-contract-paused()`
- `get-total-locked-stx()`

---

## Constants

- **Lock Duration:** 1 day min, 1 year max
- **Amount:** 1 STX min, 1M STX max
- **Bonus Rate:** 100% min, 300% max
- **Beneficiaries:** Up to 5 per user
- **Delegates:** Up to 10 per user

---

## Safety Features

- Safe arithmetic operations prevent overflows
- Principal validation for all addresses
- Contract principal validation for tokens
- Comprehensive error handling with specific codes
- Emergency mode for admin recovery
- Contract pause mechanism

---

## Usage Examples

1. **Lock STX:**
    ```clarity
    (lock-funds u1000000 u5000)
    ```
2. **Add Beneficiary:**
    ```clarity
    (add-beneficiary 'ST1234... u20)  ;; 20% share
    ```
3. **Lock Tokens:**
    ```clarity
    (lock-token-funds token-contract u1000000 u5000)
    ```
4. **Partial Withdraw:**
    ```clarity
    (partial-withdraw u500000)
    ```

---

## License

MIT (see repository for details)
