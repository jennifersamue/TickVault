# TickVault Smart Contract

TickVault is a Clarity smart contract for locking STX or fungible tokens for a fixed period, earning rewards based on lock duration. It includes admin controls, emergency features, and safe arithmetic to prevent overflows.

---

## Features

- **Lock STX or tokens** for a set duration (1 day to 1 year)
- **Earn bonus rewards** based on lock duration and tier
- **Withdraw funds** after unlock, fully or partially
- **Admin controls** for pausing, emergency mode, and tier management
- **Emergency withdrawal** by admin in emergency mode
- **Safe arithmetic** and strict validation for security

---

## Data Structures

- **Vaults:** Store locked STX per user
- **Token Vaults:** Store locked tokens per user and token contract
- **Tier Rewards:** Map lock durations to bonus rates
- **Beneficiaries & Delegates:** (Defined, not fully implemented in core logic)
- **User Stats:** Track total locked, withdrawn, and lock count

---

## Main Functions

### Public Functions

- `lock-funds(amount, unlock-height)`  
  Lock STX for a period, earning a bonus.

- `withdraw()`  
  Withdraw all unlocked STX (with bonus).

- `partial-withdraw(withdraw-amount)`  
  Withdraw part of unlocked STX.

- `lock-token-funds(token-contract, amount, unlock-height)`  
  Lock fungible tokens for a period.

- `withdraw-tokens(token-contract)`  
  Withdraw unlocked tokens.

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

---

## Constants

- **Lock Duration:** 1 day min, 1 year max
- **Amount:** 1 STX min, 1M STX max
- **Bonus Rate:** 100% min, 300% max
- **Beneficiaries:** Up to 5 per user
- **Delegates:** Up to 10 per user

---

## Error Codes

- Unauthorized, invalid amount/duration, vault not found, still locked, insufficient balance, emergency mode required, invalid bonus rate, too many delegates, transfer failed, arithmetic overflow, etc.

---

## Usage Example

1. **Lock STX:**
    ```
    (lock-funds u1000000 u5000)
    ```
2. **Withdraw after unlock:**
    ```
    (withdraw)
    ```
3. **Lock tokens:**
    ```
    (lock-token-funds token-contract u1000000 u5000)
    ```
4. **Admin sets tier reward:**
    ```
    (set-tier-reward u144 u120)
    ```

---

## Security

- All operations validated for correct amounts, durations, and contract state.
- Safe arithmetic prevents overflows.
- Emergency mode allows admin to recover funds if needed.

---

## License

MIT (see repository for details)---

## Security

- All operations validated for correct amounts, durations, and contract state.
- Safe arithmetic prevents overflows.
- Emergency mode allows admin to recover funds if needed.

---

## License

MIT (see repository for details)
