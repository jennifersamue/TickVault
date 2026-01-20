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

;; System principals to reject
(define-constant BURN_ADDRESS 'SP000000000000000000002Q6VF78)
(define-constant SYSTEM_ADDRESS 'ST000000000000000000002AMW42H)

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
(define-constant ERR_INVALID_PRINCIPAL (err u117))
(define-constant ERR_INVALID_CONTRACT (err u118))
(define-constant ERR_INSUFFICIENT_TREASURY (err u119))

;; ===== DATA VARIABLES =====
(define-data-var contract-admin principal CONTRACT_OWNER)
(define-data-var emergency-mode bool false)
(define-data-var total-locked-stx uint u0)
(define-data-var contract-paused bool false)
;; Treasury management variables
(define-data-var bonus-treasury uint u0)
(define-data-var total-bonus-obligations uint u0)

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

;; ===== VALIDATION FUNCTIONS =====
(define-private (is-valid-principal (principal-to-check principal))
    (and 
        (not (is-eq principal-to-check BURN_ADDRESS))
        (not (is-eq principal-to-check SYSTEM_ADDRESS))
        (not (is-eq principal-to-check 'SP000000000000000000002Q6VF78))))

(define-private (is-valid-contract-principal (contract-principal principal))
    (and 
        (is-valid-principal contract-principal)
        (is-ok (principal-destruct? contract-principal))))

(define-private (validate-amount (amount uint))
    (and (>= amount MIN_AMOUNT) (<= amount MAX_AMOUNT)))

(define-private (validate-duration (duration uint))
    (and (>= duration MIN_LOCK_DURATION) (<= duration MAX_LOCK_DURATION)))

(define-private (validate-unlock-height (unlock-height uint))
    (> unlock-height stacks-block-height))

(define-private (validate-bonus-rate (bonus-rate uint))
    (and (>= bonus-rate MIN_BONUS_RATE) (<= bonus-rate MAX_BONUS_RATE)))

;; ===== HELPER FUNCTIONS =====
(define-private (validate-lock-params (amount uint) (duration uint) (unlock-height uint))
    (begin
        (asserts! (validate-amount amount) ERR_INVALID_AMOUNT)
        (asserts! (validate-duration duration) ERR_INVALID_DURATION)
        (asserts! (validate-unlock-height unlock-height) ERR_INVALID_DURATION)
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
            ;; Validate all beneficiary principals
            (asserts! (is-eq (len (filter is-valid-beneficiary-entry beneficiaries-list)) num-beneficiaries) ERR_INVALID_PRINCIPAL)
            (ok true)
        )))

(define-private (is-valid-beneficiary-entry (entry { beneficiary: principal, share: uint, approved: bool }))
    (and 
        (is-valid-principal (get beneficiary entry))
        (> (get share entry) u0)
        (<= (get share entry) u100)))

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

;; ===== TREASURY MANAGEMENT FUNCTIONS =====
(define-public (fund-bonus-treasury (amount uint))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (let ((new-treasury (unwrap! (safe-add (var-get bonus-treasury) amount) ERR_ARITHMETIC_OVERFLOW)))
            (var-set bonus-treasury new-treasury))
        (ok amount)))

(define-public (withdraw-from-treasury (amount uint) (recipient principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (asserts! (is-valid-principal recipient) ERR_INVALID_PRINCIPAL)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (let (
            (current-treasury (var-get bonus-treasury))
            (current-obligations (var-get total-bonus-obligations))
            (available-treasury (if (>= current-treasury current-obligations) 
                                   (- current-treasury current-obligations) 
                                   u0))
        )
            (begin
                (asserts! (>= available-treasury amount) ERR_INSUFFICIENT_TREASURY)
                (try! (as-contract (stx-transfer? amount tx-sender recipient)))
                (let ((new-treasury (unwrap! (safe-subtract current-treasury amount) ERR_INSUFFICIENT_BALANCE)))
                    (var-set bonus-treasury new-treasury))
                (ok amount)))))

;; ===== ADMIN FUNCTIONS =====
(define-public (set-contract-admin (new-admin principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        ;; Validate the new admin principal
        (asserts! (is-valid-principal new-admin) ERR_INVALID_PRINCIPAL)
        (asserts! (not (is-eq new-admin tx-sender)) ERR_INVALID_PRINCIPAL)
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
        (asserts! (validate-duration duration) ERR_INVALID_DURATION)
        (asserts! (validate-bonus-rate bonus-rate) ERR_INVALID_BONUS_RATE)
        (ok (map-set tier-rewards 
            { lock-duration: duration }
            { bonus-rate: bonus-rate }))))

;; ===== CORE VAULT FUNCTIONS =====
(define-public (lock-funds (amount uint) (unlock-height uint))
    (let (
        (validated-amount (begin 
            (asserts! (validate-amount amount) ERR_INVALID_AMOUNT)
            amount))
        (validated-unlock-height (begin
            (asserts! (validate-unlock-height unlock-height) ERR_INVALID_DURATION)
            unlock-height))
        (duration (unwrap! (safe-subtract validated-unlock-height stacks-block-height) ERR_INVALID_DURATION))
        (bonus-info (get-tier-bonus duration))
        (bonus-rate (get bonus-rate bonus-info))
        ;; Calculate actual bonus amount (not total with bonus)
        (bonus-calculation (unwrap! (safe-multiply validated-amount (- bonus-rate u100)) ERR_ARITHMETIC_OVERFLOW))
        (bonus-amount (/ bonus-calculation u100))
        (total-amount (unwrap! (safe-add validated-amount bonus-amount) ERR_ARITHMETIC_OVERFLOW)))
        (begin
            ;; Pre-conditions
            (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
            (try! (validate-lock-params validated-amount duration validated-unlock-height))
            (asserts! (is-none (map-get? stx-vault { owner: tx-sender })) ERR_VAULT_EXISTS)
            
            ;; Ensure treasury can cover bonus obligations
            (let ((new-bonus-obligations (unwrap! (safe-add (var-get total-bonus-obligations) bonus-amount) ERR_ARITHMETIC_OVERFLOW)))
                (asserts! (<= new-bonus-obligations (var-get bonus-treasury)) ERR_INSUFFICIENT_TREASURY)
                (var-set total-bonus-obligations new-bonus-obligations))
            
            ;; FIXED: Transfer STX from user to contract
            (try! (stx-transfer? validated-amount tx-sender (as-contract tx-sender)))
            
            ;; Update state with safe operations
            (let ((new-total-locked (unwrap! (safe-add (var-get total-locked-stx) validated-amount) ERR_ARITHMETIC_OVERFLOW)))
                (var-set total-locked-stx new-total-locked))
            (unwrap! (update-user-stats tx-sender validated-amount u0 u1) ERR_ARITHMETIC_OVERFLOW)
            
            ;; Create vault entry with separate tracking of original and bonus amounts
            (ok (map-set stx-vault 
                { owner: tx-sender }
                { 
                    amount: total-amount,  ;; Total withdrawable amount
                    unlock-height: validated-unlock-height,
                    original-amount: validated-amount,
                    lock-timestamp: stacks-block-height
                })))))

(define-public (withdraw)
    (let ((vault-info (unwrap! (map-get? stx-vault { owner: tx-sender }) ERR_VAULT_NOT_FOUND)))
        (begin
            (asserts! (>= stacks-block-height (get unlock-height vault-info)) ERR_STILL_LOCKED)
            (asserts! (> (get amount vault-info) u0) ERR_INSUFFICIENT_BALANCE)
            
            (let (
                (caller tx-sender)
                (total-withdraw-amount (get amount vault-info))
                (original-amount (get original-amount vault-info))
                (bonus-amount (unwrap! (safe-subtract total-withdraw-amount original-amount) ERR_ARITHMETIC_OVERFLOW))
            )
                (begin
                    ;; FIXED: Transfer original amount from locked funds
                    (try! (as-contract (stx-transfer? original-amount tx-sender caller)))
                    
                    ;; Transfer bonus from treasury if any
                    (if (> bonus-amount u0)
                        (begin
                            (try! (as-contract (stx-transfer? bonus-amount tx-sender caller)))
                            ;; Update treasury and obligations
                            (let ((new-treasury (unwrap! (safe-subtract (var-get bonus-treasury) bonus-amount) ERR_INSUFFICIENT_BALANCE))
                                  (new-obligations (unwrap! (safe-subtract (var-get total-bonus-obligations) bonus-amount) ERR_INSUFFICIENT_BALANCE)))
                                (var-set bonus-treasury new-treasury)
                                (var-set total-bonus-obligations new-obligations)))
                        true)
                    
                    ;; Update state
                    (let ((new-total-locked (unwrap! (safe-subtract (var-get total-locked-stx) original-amount) ERR_INSUFFICIENT_BALANCE)))
                        (var-set total-locked-stx new-total-locked))
                    (unwrap! (update-user-stats tx-sender u0 total-withdraw-amount u0) ERR_ARITHMETIC_OVERFLOW)
                    
                    ;; Clean up
                    (map-delete stx-vault { owner: tx-sender })
                    (ok total-withdraw-amount))))))

(define-public (partial-withdraw (withdraw-amount uint))
    (let ((vault-info (unwrap! (map-get? stx-vault { owner: tx-sender }) ERR_VAULT_NOT_FOUND)))
        (begin
            (asserts! (>= stacks-block-height (get unlock-height vault-info)) ERR_STILL_LOCKED)
            (asserts! (>= (get amount vault-info) withdraw-amount) ERR_INSUFFICIENT_BALANCE)
            (asserts! (> withdraw-amount u0) ERR_INVALID_AMOUNT)
            
            (let (
                (caller tx-sender)
                (current-amount (get amount vault-info))
                (original-amount (get original-amount vault-info))
                (remaining-amount (unwrap! (safe-subtract current-amount withdraw-amount) ERR_INSUFFICIENT_BALANCE))
                (total-bonus (unwrap! (safe-subtract current-amount original-amount) ERR_ARITHMETIC_OVERFLOW))
                ;; Calculate proportional bonus for this withdrawal
                (bonus-portion (if (> total-bonus u0) (/ (* total-bonus withdraw-amount) current-amount) u0))
                (principal-portion (- withdraw-amount bonus-portion))
            )
                (begin
                    ;; FIXED: Transfer principal portion from locked funds
                    (try! (as-contract (stx-transfer? principal-portion tx-sender caller)))
                    
                    ;; Transfer bonus portion from treasury if any
                    (if (> bonus-portion u0)
                        (begin
                            (try! (as-contract (stx-transfer? bonus-portion tx-sender caller)))
                            ;; Update treasury and obligations
                            (let ((new-treasury (unwrap! (safe-subtract (var-get bonus-treasury) bonus-portion) ERR_INSUFFICIENT_BALANCE))
                                  (new-obligations (unwrap! (safe-subtract (var-get total-bonus-obligations) bonus-portion) ERR_INSUFFICIENT_BALANCE)))
                                (var-set bonus-treasury new-treasury)
                                (var-set total-bonus-obligations new-obligations)))
                        true)
                    
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
            (asserts! (validate-amount amount) ERR_INVALID_AMOUNT)
            amount))
        (validated-unlock-height (begin
            (asserts! (validate-unlock-height unlock-height) ERR_INVALID_DURATION)
            unlock-height))
        (duration (unwrap! (safe-subtract validated-unlock-height stacks-block-height) ERR_INVALID_DURATION))
        (token-principal (contract-of token-contract)))
        (begin
            (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
            ;; Validate token contract principal
            (asserts! (is-valid-contract-principal token-principal) ERR_INVALID_CONTRACT)
            (try! (validate-lock-params validated-amount duration validated-unlock-height))
            (asserts! (is-none (map-get? token-vault { owner: tx-sender, token-contract: token-principal })) ERR_VAULT_EXISTS)
            
            ;; FIXED: Transfer tokens from user to contract with proper SIP-010 signature
            (match (contract-call? token-contract transfer validated-amount tx-sender (as-contract tx-sender) none)
                success (begin
                    (asserts! success ERR_TRANSFER_FAILED)
                    (map-set token-vault 
                        { owner: tx-sender, token-contract: token-principal }
                        { 
                            amount: validated-amount,
                            unlock-height: validated-unlock-height,
                            original-amount: validated-amount,
                            lock-timestamp: stacks-block-height
                        })
                    (unwrap! (update-user-stats tx-sender validated-amount u0 u1) ERR_ARITHMETIC_OVERFLOW)
                    (ok true))
                error ERR_TRANSFER_FAILED))))

(define-public (withdraw-tokens (token-contract <token-trait>))
    (let (
        (token-principal (contract-of token-contract))
        (vault-info (unwrap! (map-get? token-vault { owner: tx-sender, token-contract: token-principal }) ERR_VAULT_NOT_FOUND)))
        (begin
            (asserts! (>= stacks-block-height (get unlock-height vault-info)) ERR_STILL_LOCKED)
            ;; Validate token contract principal
            (asserts! (is-valid-contract-principal token-principal) ERR_INVALID_CONTRACT)
            
            (let (
                (caller tx-sender)
                (withdraw-amount (get amount vault-info))
            )
                (begin
                    (asserts! (> withdraw-amount u0) ERR_INSUFFICIENT_BALANCE)
                    
                    ;; FIXED: Transfer tokens from contract back to user
                    (match (as-contract (contract-call? token-contract transfer 
                        withdraw-amount 
                        tx-sender  ;; from: contract (as-contract context)
                        caller  ;; to: original caller (vault owner)
                        none))
                        success (begin
                            (asserts! success ERR_TRANSFER_FAILED)
                            (map-delete token-vault { owner: tx-sender, token-contract: token-principal })
                            (unwrap! (update-user-stats tx-sender u0 withdraw-amount u0) ERR_ARITHMETIC_OVERFLOW)
                            (ok withdraw-amount))
                        error ERR_TRANSFER_FAILED))))))

(define-public (partial-withdraw-tokens (token-contract <token-trait>) (withdraw-amount uint))
    (let (
        (token-principal (contract-of token-contract))
        (vault-info (unwrap! (map-get? token-vault { owner: tx-sender, token-contract: token-principal }) ERR_VAULT_NOT_FOUND)))
        (begin
            (asserts! (>= stacks-block-height (get unlock-height vault-info)) ERR_STILL_LOCKED)
            (asserts! (> withdraw-amount u0) ERR_INVALID_AMOUNT)
            (asserts! (>= (get amount vault-info) withdraw-amount) ERR_INSUFFICIENT_BALANCE)
            ;; Validate token contract principal
            (asserts! (is-valid-contract-principal token-principal) ERR_INVALID_CONTRACT)
            
            (let (
                (caller tx-sender)
                (current-amount (get amount vault-info))
                (remaining-amount (unwrap! (safe-subtract current-amount withdraw-amount) ERR_INSUFFICIENT_BALANCE))
            )
                (begin
                    ;; FIXED: Transfer tokens from contract back to user
                    (match (as-contract (contract-call? token-contract transfer 
                        withdraw-amount 
                        tx-sender  ;; from: contract (as-contract context)
                        caller  ;; to: original caller (vault owner)
                        none))
                        success (begin
                            (asserts! success ERR_TRANSFER_FAILED)
                            ;; Update vault or delete if empty
                            (if (is-eq remaining-amount u0)
                                (map-delete token-vault { owner: tx-sender, token-contract: token-principal })
                                (map-set token-vault 
                                    { owner: tx-sender, token-contract: token-principal }
                                    (merge vault-info { amount: remaining-amount })))
                            
                            (unwrap! (update-user-stats tx-sender u0 withdraw-amount u0) ERR_ARITHMETIC_OVERFLOW)
                            (ok withdraw-amount))
                        error ERR_TRANSFER_FAILED))))))

;; ===== BENEFICIARY FUNCTIONS =====
(define-public (add-beneficiary (beneficiary principal) (share uint))
    (let (
        (current-beneficiaries (default-to (list) (map-get? beneficiaries tx-sender)))
        (current-count (len current-beneficiaries))
    )
        (begin
            (asserts! (< current-count MAX_BENEFICIARIES) ERR_INVALID_BENEFICIARIES)
            (asserts! (> share u0) ERR_INVALID_SHARES)
            (asserts! (<= share u100) ERR_INVALID_SHARES)
            ;; Validate beneficiary principal
            (asserts! (is-valid-principal beneficiary) ERR_INVALID_PRINCIPAL)
            (asserts! (not (is-eq beneficiary tx-sender)) ERR_INVALID_PRINCIPAL)
            
            ;; Check total shares don't exceed 100%
            (let ((total-shares (fold + (map get-beneficiary-share current-beneficiaries) share)))
                (asserts! (<= total-shares u100) ERR_INVALID_SHARES)
                
                (map-set beneficiaries tx-sender 
                    (unwrap! (as-max-len? (append current-beneficiaries {beneficiary: beneficiary, share: share, approved: false}) u5) 
                             ERR_INVALID_BENEFICIARIES))
                (ok true)))))

(define-public (approve-beneficiary-status)
    (let (
        (current-beneficiaries (unwrap! (map-get? beneficiaries tx-sender) ERR_NOT_BENEFICIARY))
    )
        (begin
            (asserts! (is-beneficiary-in-list current-beneficiaries tx-sender) ERR_NOT_BENEFICIARY)
            (map-set beneficiaries tx-sender (map update-beneficiary-approval current-beneficiaries))
            (ok true))))

;; ===== EMERGENCY FUNCTIONS =====
(define-public (emergency-withdraw (user principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-admin)) ERR_UNAUTHORIZED)
        (asserts! (var-get emergency-mode) ERR_EMERGENCY_MODE_REQUIRED)
        ;; Validate user principal
        (asserts! (is-valid-principal user) ERR_INVALID_PRINCIPAL)
        
        (match (map-get? stx-vault { owner: user })
            vault-info (let (
                (total-withdraw-amount (get amount vault-info))
                (original-amount (get original-amount vault-info))
                (bonus-amount (unwrap! (safe-subtract total-withdraw-amount original-amount) ERR_ARITHMETIC_OVERFLOW))
            )
                (begin
                    ;; FIXED: Transfer original amount from locked funds to vault owner
                    (try! (as-contract (stx-transfer? original-amount tx-sender user)))
                    
                    ;; Transfer bonus from treasury if any
                    (if (> bonus-amount u0)
                        (begin
                            (try! (as-contract (stx-transfer? bonus-amount tx-sender user)))
                            ;; Update treasury and obligations
                            (let ((new-treasury (unwrap! (safe-subtract (var-get bonus-treasury) bonus-amount) ERR_INSUFFICIENT_BALANCE))
                                  (new-obligations (unwrap! (safe-subtract (var-get total-bonus-obligations) bonus-amount) ERR_INSUFFICIENT_BALANCE)))
                                (var-set bonus-treasury new-treasury)
                                (var-set total-bonus-obligations new-obligations)))
                        true)
                    
                    ;; Update state
                    (let ((new-total-locked (unwrap! (safe-subtract (var-get total-locked-stx) original-amount) ERR_INSUFFICIENT_BALANCE)))
                        (var-set total-locked-stx new-total-locked))
                    
                    ;; Clean up vault
                    (map-delete stx-vault { owner: user })
                    (ok total-withdraw-amount)))
            ERR_VAULT_NOT_FOUND)))

;; ===== READ-ONLY FUNCTIONS =====
(define-read-only (get-vault-info (owner principal))
    (map-get? stx-vault { owner: owner }))

(define-read-only (get-token-vault-info (owner principal) (token-contract principal))
    (map-get? token-vault { owner: owner, token-contract: token-contract }))

(define-read-only (get-user-stats (user principal))
    (map-get? user-stats user))

(define-read-only (get-tier-reward (duration uint))
    (map-get? tier-rewards { lock-duration: duration }))

(define-read-only (get-contract-admin)
    (var-get contract-admin))

(define-read-only (get-emergency-mode)
    (var-get emergency-mode))

(define-read-only (get-contract-paused)
    (var-get contract-paused))

(define-read-only (get-total-locked-stx)
    (var-get total-locked-stx))

;; Treasury read-only functions
(define-read-only (get-bonus-treasury)
    (var-get bonus-treasury))

(define-read-only (get-total-bonus-obligations)
    (var-get total-bonus-obligations))

(define-read-only (get-available-treasury)
    (let (
        (treasury (var-get bonus-treasury))
        (obligations (var-get total-bonus-obligations))
    )
        (if (>= treasury obligations) 
            (- treasury obligations) 
            u0)))

;; Contract balance verification
(define-read-only (verify-contract-balance)
    (let (
        (contract-balance (stx-get-balance (as-contract tx-sender)))
        (tracked-balance (+ (var-get total-locked-stx) (var-get bonus-treasury)))
    )
        {
            contract-balance: contract-balance,
            tracked-balance: tracked-balance,
            balance-matches: (>= contract-balance tracked-balance)
        }))
