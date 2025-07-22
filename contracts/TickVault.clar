;; ===== TRAITS =====
(define-trait token-trait
    (
        (transfer (uint principal principal (optional (buff 34))) (response bool uint))
        (get-balance (principal) (response uint uint))
        (get-total-supply () (response uint uint))
        (get-name () (response (string-ascii 32) uint))
        (get-symbol () (response (string-ascii 10) uint))
        (get-decimals () (response uint uint))
        (get-token-uri () (response (optional (string-utf8 256)) uint))
    )
)

;; ===== CONSTANTS =====
(define-constant CONTRACT_OWNER tx-sender)
(define-constant BLOCKS_PER_DAY u144)
(define-constant BLOCKS_PER_WEEK (* BLOCKS_PER_DAY u7))
(define-constant BLOCKS_PER_MONTH (* BLOCKS_PER_DAY u30))
(define-constant BLOCKS_PER_YEAR (* BLOCKS_PER_DAY u365))

;; Lock duration limits
(define-constant MIN_LOCK_DURATION BLOCKS_PER_DAY)  ;; 1 day minimum
(define-constant MAX_LOCK_DURATION BLOCKS_PER_YEAR)  ;; 1 year maximum

;; Amount limits (in microSTX)
(define-constant MIN_AMOUNT u1000000)  ;; 1 STX minimum
(define-constant MAX_AMOUNT u1000000000000)  ;; 1M STX maximum

;; Bonus rate limits
(define-constant MIN_BONUS_RATE u100)  ;; 100% (no penalty)
(define-constant MAX_BONUS_RATE u300)  ;; 300% (3x reward)

;; List limits
(define-constant MAX_BENEFICIARIES u5)
(define-constant MAX_DELEGATES u10)

;; ===== ERROR CODES =====
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_AMOUNT (err u101))
(define-constant ERR_INVALID_DURATION (err u102))
(define-constant ERR_VAULT_NOT_FOUND (err u103))
(define-constant ERR_STILL_LOCKED (err u104))
(define-constant ERR_INSUFFICIENT_BALANCE (err u105))
(define-constant ERR_EMERGENCY_MODE_REQUIRED (err u106))
(define-constant ERR_INVALID_BONUS_RATE (err u107))
(define-constant ERR_INVALID_BENEFICIARIES (err u108))
(define-constant ERR_TOO_MANY_DELEGATES (err u109))
(define-constant ERR_DELEGATE_EXISTS (err u110))
(define-constant ERR_INVALID_TOKEN (err u111))
(define-constant ERR_TRANSFER_FAILED (err u112))
(define-constant ERR_INVALID_SHARES (err u113))
(define-constant ERR_NOT_BENEFICIARY (err u114))
(define-constant ERR_VAULT_EXISTS (err u115))
(define-constant ERR_ARITHMETIC_OVERFLOW (err u116))

;; ===== DATA VARIABLES =====
(define-data-var contract-admin principal CONTRACT_OWNER)
(define-data-var emergency-mode bool false)
(define-data-var total-locked-stx uint u0)
(define-data-var contract-paused bool false)

;; ===== DATA MAPS =====
(define-map stx-vault 
    { owner: principal } 
    { 
        amount: uint, 
        unlock-height: uint,
        original-amount: uint,
        lock-timestamp: uint
    })

(define-map token-vault
    { owner: principal, token-contract: principal }
    { 
        amount: uint, 
        unlock-height: uint,
        original-amount: uint,
        lock-timestamp: uint
    })

(define-map tier-rewards
    { lock-duration: uint }
    { bonus-rate: uint })

(define-map beneficiaries 
    principal 
    (list 5 { 
        beneficiary: principal, 
        share: uint,
        approved: bool 
    }))

(define-map delegates 
    principal 
    (list 10 principal))

(define-map user-stats
    principal
    {
        total-locked: uint,
        total-withdrawn: uint,
        lock-count: uint
    })

;; ===== HELPER FUNCTIONS =====
(define-private (validate-lock-params (amount uint) (duration uint) (unlock-height uint))
    (begin
        (asserts! (and (>= amount MIN_AMOUNT) (<= amount MAX_AMOUNT)) ERR_INVALID_AMOUNT)
        (asserts! (and (>= duration MIN_LOCK_DURATION) (<= duration MAX_LOCK_DURATION)) ERR_INVALID_DURATION)
        (asserts! (> unlock-height stacks-block-height) ERR_INVALID_DURATION)
        (ok true)))

(define-private (get-tier-bonus (duration uint))
    (default-to { bonus-rate: MIN_BONUS_RATE }
        (map-get? tier-rewards { lock-duration: duration })))

;; Safe arithmetic operations to prevent overflow
(define-private (safe-multiply (a uint) (b uint))
    (let ((result (* a b)))
        (if (and (> a u0) (> b u0) (< result a))
            (err ERR_ARITHMETIC_OVERFLOW)
            (ok result))))

(define-private (safe-add (a uint) (b uint))
    (let ((result (+ a b)))
        (if (< result a)
            (err ERR_ARITHMETIC_OVERFLOW)
            (ok result))))

(define-private (safe-subtract (a uint) (b uint))
    (if (>= a b)
        (ok (- a b))
        (err ERR_INSUFFICIENT_BALANCE)))

(define-private (update-user-stats (user principal) (locked uint) (withdrawn uint) (lock-count-delta uint))
    (let (
        (stats (default-to { total-locked: u0, total-withdrawn: u0, lock-count: u0 } (map-get? user-stats user)))
        (new-total-locked-result (safe-add (get total-locked stats) locked))
        (new-total-withdrawn-result (safe-add (get total-withdrawn stats) withdrawn))
        (new-lock-count-result (safe-add (get lock-count stats) lock-count-delta))
    )
        (match new-total-locked-result
            new-total-locked (match new-total-withdrawn-result
                new-total-withdrawn (match new-lock-count-result
                    new-lock-count (begin
                        (map-set user-stats user {
                            total-locked: new-total-locked,
                            total-withdrawn: new-total-withdrawn,
                            lock-count: new-lock-count
                        })
                        (ok true))
                    error (err error))
                error (err error))
            error (err error))))

(define-private (validate-beneficiaries (beneficiaries-list (list 5 { beneficiary: principal, share: uint, approved: bool })))
    (let (
        (total-shares (fold + (map get-beneficiary-share beneficiaries-list) u0))
        (num-beneficiaries (len beneficiaries-list))
    )
        (begin
            (asserts! (> num-beneficiaries u0) ERR_INVALID_BENEFICIARIES)
            (asserts! (<= num-beneficiaries MAX_BENEFICIARIES) ERR_INVALID_BENEFICIARIES)
            (asserts! (is-eq total-shares u100) ERR_INVALID_SHARES)
            (ok true)
        )))

(define-private (get-beneficiary-share (entry { beneficiary: principal, share: uint, approved: bool }))
    (get share entry))

(define-private (is-beneficiary-in-list (beneficiary-list (list 5 { beneficiary: principal, share: uint, approved: bool })) (target principal))
    (> (len (filter is-target-beneficiary beneficiary-list)) u0))

(define-private (is-target-beneficiary (entry { beneficiary: principal, share: uint, approved: bool }))
    (is-eq (get beneficiary entry) tx-sender))

(define-private (update-beneficiary-approval (entry { beneficiary: principal, share: uint, approved: bool }))
    (if (is-eq (get beneficiary entry) tx-sender)
        (merge entry { approved: true })
        entry))

;; ===== ADMIN FUNCTIONS =====
(define-public (set-contract-admin (new-admin principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (var-set contract-admin new-admin)
        (ok new-admin)))

(define-public (toggle-emergency-mode)
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (ok (var-set emergency-mode (not (var-get emergency-mode))))))

(define-public (pause-contract)
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (ok (var-set contract-paused true))))

(define-public (unpause-contract)
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (ok (var-set contract-paused false))))

(define-public (set-tier-reward (duration uint) (bonus-rate uint))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (asserts! (and (>= duration MIN_LOCK_DURATION) (<= duration MAX_LOCK_DURATION)) ERR_INVALID_DURATION)
        (asserts! (and (>= bonus-rate MIN_BONUS_RATE) (<= bonus-rate MAX_BONUS_RATE)) ERR_INVALID_BONUS_RATE)
        (ok (map-set tier-rewards 
            { lock-duration: duration }
            { bonus-rate: bonus-rate }))))

;; ===== CORE VAULT FUNCTIONS =====
(define-public (lock-funds (amount uint) (unlock-height uint))
    (let (
        (validated-amount (begin 
            (asserts! (and (>= amount MIN_AMOUNT) (<= amount MAX_AMOUNT)) ERR_INVALID_AMOUNT)
            amount))
        (validated-unlock-height (begin
            (asserts! (> unlock-height stacks-block-height) ERR_INVALID_DURATION)
            unlock-height))
        (duration (unwrap! (safe-subtract validated-unlock-height stacks-block-height) ERR_INVALID_DURATION))
        (bonus-info (get-tier-bonus duration))
        (bonus-rate (get bonus-rate bonus-info))
        (bonus-calculation (unwrap! (safe-multiply validated-amount bonus-rate) ERR_ARITHMETIC_OVERFLOW))
        (bonus-amount (/ bonus-calculation u100)))
        (begin
            ;; Pre-conditions
            (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
            (try! (validate-lock-params validated-amount duration validated-unlock-height))
            (asserts! (is-none (map-get? stx-vault { owner: tx-sender })) ERR_VAULT_EXISTS)
            
            ;; Transfer STX to contract
            (try! (stx-transfer? validated-amount tx-sender (as-contract tx-sender)))
            
            ;; Update state with safe operations
            (let ((new-total-locked (unwrap! (safe-add (var-get total-locked-stx) validated-amount) ERR_ARITHMETIC_OVERFLOW)))
                (var-set total-locked-stx new-total-locked))
            (unwrap! (update-user-stats tx-sender validated-amount u0 u1) ERR_ARITHMETIC_OVERFLOW)
            
            ;; Create vault entry
            (ok (map-set stx-vault 
                { owner: tx-sender }
                { 
                    amount: bonus-amount,
                    unlock-height: validated-unlock-height,
                    original-amount: validated-amount,
                    lock-timestamp: stacks-block-height
                })))))

(define-public (withdraw)
    (let ((vault-info (unwrap! (map-get? stx-vault { owner: tx-sender }) ERR_VAULT_NOT_FOUND)))
        (begin
            (asserts! (>= stacks-block-height (get unlock-height vault-info)) ERR_STILL_LOCKED)
            (asserts! (> (get amount vault-info) u0) ERR_INSUFFICIENT_BALANCE)
            
            ;; Validate amounts before operations
            (let (
                (withdraw-amount (get amount vault-info))
                (original-amount (get original-amount vault-info))
            )
                (begin
                    ;; Transfer funds back
                    (try! (as-contract (stx-transfer? withdraw-amount tx-sender tx-sender)))
                    
                    ;; Update state with safe operations
                    (let ((new-total-locked (unwrap! (safe-subtract (var-get total-locked-stx) original-amount) ERR_INSUFFICIENT_BALANCE)))
                        (var-set total-locked-stx new-total-locked))
                    (unwrap! (update-user-stats tx-sender u0 withdraw-amount u0) ERR_ARITHMETIC_OVERFLOW)
                    
                    ;; Clean up
                    (map-delete stx-vault { owner: tx-sender })
                    (ok withdraw-amount))))))

(define-public (partial-withdraw (withdraw-amount uint))
    (let ((vault-info (unwrap! (map-get? stx-vault { owner: tx-sender }) ERR_VAULT_NOT_FOUND)))
        (begin
            (asserts! (>= stacks-block-height (get unlock-height vault-info)) ERR_STILL_LOCKED)
            (asserts! (>= (get amount vault-info) withdraw-amount) ERR_INSUFFICIENT_BALANCE)
            (asserts! (> withdraw-amount u0) ERR_INVALID_AMOUNT)
            
            ;; Validate and perform safe operations
            (let (
                (current-amount (get amount vault-info))
                (original-amount (get original-amount vault-info))
                (remaining-amount (unwrap! (safe-subtract current-amount withdraw-amount) ERR_INSUFFICIENT_BALANCE))
            )
                (begin
                    ;; Transfer partial amount
                    (try! (as-contract (stx-transfer? withdraw-amount tx-sender tx-sender)))
                    
                    ;; Update vault or delete if empty
                    (if (is-eq remaining-amount u0)
                        (begin
                            (map-delete stx-vault { owner: tx-sender })
                            (let ((new-total-locked (unwrap! (safe-subtract (var-get total-locked-stx) original-amount) ERR_INSUFFICIENT_BALANCE)))
                                (var-set total-locked-stx new-total-locked)))
                        (map-set stx-vault 
                            { owner: tx-sender }
                            (merge vault-info { amount: remaining-amount })))
                    
                    (unwrap! (update-user-stats tx-sender u0 withdraw-amount u0) ERR_ARITHMETIC_OVERFLOW)
                    (ok withdraw-amount))))))

;; ===== TOKEN VAULT FUNCTIONS =====
(define-public (lock-token-funds 
    (token-contract <token-trait>)
    (amount uint) 
    (unlock-height uint))
    (let (
        (validated-amount (begin 
            (asserts! (and (>= amount MIN_AMOUNT) (<= amount MAX_AMOUNT)) ERR_INVALID_AMOUNT)
            amount))
        (validated-unlock-height (begin
            (asserts! (> unlock-height stacks-block-height) ERR_INVALID_DURATION)
            unlock-height))
        (duration (unwrap! (safe-subtract validated-unlock-height stacks-block-height) ERR_INVALID_DURATION))
        (token-principal (contract-of token-contract)))
        (begin
            (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
            (try! (validate-lock-params validated-amount duration validated-unlock-height))
            (asserts! (is-none (map-get? token-vault { owner: tx-sender, token-contract: token-principal })) ERR_VAULT_EXISTS)
            
            ;; Transfer tokens to contract
            (match (contract-call? token-contract transfer validated-amount tx-sender (as-contract tx-sender) none)
                success (begin
                    (map-set token-vault 
                        { owner: tx-sender, token-contract: token-principal }
                        { 
                            amount: validated-amount,
                            unlock-height: validated-unlock-height,
                            original-amount: validated-amount,
                            lock-timestamp: stacks-block-height
                        })
                    (ok true))
                error ERR_TRANSFER_FAILED))))

(define-public (withdraw-tokens (token-contract <token-trait>))
    (let (
        (token-principal (contract-of token-contract))
        (vault-info (unwrap! (map-get? token-vault { owner: tx-sender, token-contract: token-principal }) ERR_VAULT_NOT_FOUND)))
        (begin
            (asserts! (>= stacks-block-height (get unlock-height vault-info)) ERR_STILL_LOCKED)
            
            ;; Validate amount before transfer
            (let ((withdraw-amount (get amount vault-info)))
                (begin
                    (asserts! (> withdraw-amount u0) ERR_INSUFFICIENT_BALANCE)
                    
                    ;; Transfer tokens back
                    (match (as-contract (contract-call? token-contract transfer 
                        withdraw-amount 
                        tx-sender 
                        tx-sender 
                        none))
                        success (begin
                            (map-delete token-vault { owner: tx-sender, token-contract: token-principal })
                            (ok withdraw-amount))
                        error ERR_TRANSFER_FAILED))))))

;; ===== EMERGENCY FUNCTIONS =====
(define-public (emergency-withdraw (user principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (asserts! (var-get emergency-mode) ERR_EMERGENCY_MODE_REQUIRED)
        
        (match (map-get? stx-vault { owner: user })
            vault-info (begin
                ;; Add your emergency withdrawal logic here, e.g. transfer funds to user, update state, etc.
                (ok vault-info))
            ERR_VAULT_NOT_FOUND)))