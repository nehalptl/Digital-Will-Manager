;; Digital Will Manager Contract
;; A blockchain-based digital will management system for secure inheritance

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-will-not-found (err u104))
(define-constant err-will-already-exists (err u105))
(define-constant err-not-executor (err u106))
(define-constant err-will-not-activated (err u107))

;; Data Variables
(define-data-var total-wills uint u0)
(define-data-var contract-fee uint u100000) ;; 0.1 STX fee for creating will

;; Data Maps
(define-map digital-wills 
  principal ;; testator (will creator)
  {
    executor: principal,
    beneficiaries: (list 10 principal),
    asset-distribution: (list 10 {beneficiary: principal, percentage: uint}),
    will-content: (string-ascii 500),
    creation-time: uint,
    is-active: bool,
    is-executed: bool,
    required-confirmations: uint,
    total-assets: uint
  })

(define-map will-assets principal uint) ;; Track STX assets locked in will
(define-map execution-confirmations {testator: principal, confirmer: principal} bool)

;; Function 1: Create Digital Will
(define-public (create-will 
  (executor principal)
  (beneficiaries (list 10 principal))
  (asset-percentages (list 10 uint))
  (will-content (string-ascii 500))
  (required-confirmations uint)
  (initial-assets uint))
  (let (
    (testator tx-sender)
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
    (fee (var-get contract-fee))
    (total-percentage (fold + asset-percentages u0))
    (asset-distribution (map create-distribution beneficiaries asset-percentages))
  )
    ;; Check if will already exists
    (asserts! (is-none (map-get? digital-wills testator)) err-will-already-exists)
    
    ;; Validate percentage distribution (should total 100%)
    (asserts! (is-eq total-percentage u100) (err u108)) ;; err-invalid-distribution
    
    ;; Validate initial assets and fee
    (asserts! (>= (stx-get-balance testator) (+ initial-assets fee)) err-insufficient-balance)
    (asserts! (> initial-assets u0) err-invalid-amount)
    (asserts! (> required-confirmations u0) err-invalid-amount)
    
    ;; Transfer fee to contract
    (try! (stx-transfer? fee testator (as-contract tx-sender)))
    
    ;; Lock initial assets in will
    (try! (stx-transfer? initial-assets testator (as-contract tx-sender)))
    
    ;; Create will record
    (map-set digital-wills testator {
      executor: executor,
      beneficiaries: beneficiaries,
      asset-distribution: asset-distribution,
      will-content: will-content,
      creation-time: current-time,
      is-active: true,
      is-executed: false,
      required-confirmations: required-confirmations,
      total-assets: initial-assets
    })
    
    ;; Track assets
    (map-set will-assets testator initial-assets)
    
    ;; Increment total wills
    (var-set total-wills (+ (var-get total-wills) u1))
    
    (print {
      event: "will-created",
      testator: testator,
      executor: executor,
      beneficiaries: beneficiaries,
      total-assets: initial-assets,
      creation-time: current-time
    })
    
    (ok {
      message: "Digital will created successfully",
      will-id: testator,
      total-assets: initial-assets,
      executor: executor
    })))

;; Function 2: Execute Will (Distribute Assets)
(define-public (execute-will (testator principal))
  (let (
    (will-data (unwrap! (map-get? digital-wills testator) err-will-not-found))
    (executor tx-sender)
    (total-assets (get total-assets will-data))
    (asset-distribution (get asset-distribution will-data))
    (required-confirmations (get required-confirmations will-data))
  )
    ;; Check if caller is the designated executor
    (asserts! (is-eq executor (get executor will-data)) err-not-executor)
    
    ;; Check if will is active and not already executed
    (asserts! (get is-active will-data) err-will-not-activated)
    (asserts! (not (get is-executed will-data)) (err u109)) ;; err-already-executed
    
    ;; Distribute assets to beneficiaries
    (try! (fold distribute-assets asset-distribution (ok u0)))
    
    ;; Mark will as executed
    (map-set digital-wills testator
      (merge will-data {is-executed: true, is-active: false}))
    
    ;; Clear asset tracking
    (map-delete will-assets testator)
    
    (print {
      event: "will-executed",
      testator: testator,
      executor: executor,
      total-distributed: total-assets,
      beneficiaries: (get beneficiaries will-data)
    })
    
    (ok {
      message: "Will executed successfully",
      total-distributed: total-assets,
      beneficiaries-count: (len (get beneficiaries will-data))
    })))

;; Helper function to create asset distribution mapping
(define-private (create-distribution (beneficiary principal) (percentage uint))
  {beneficiary: beneficiary, percentage: percentage})

;; Helper function to distribute assets to beneficiaries
(define-private (distribute-assets 
  (distribution {beneficiary: principal, percentage: uint}) 
  (previous-result (response uint uint)))
  (let (
    (beneficiary (get beneficiary distribution))
    (percentage (get percentage distribution))
    (testator-assets (unwrap-panic (map-get? will-assets tx-sender)))
    (distribution-amount (/ (* testator-assets percentage) u100))
  )
    (match previous-result
      success-val
        (begin
          (try! (as-contract (stx-transfer? distribution-amount tx-sender beneficiary)))
          (ok (+ success-val distribution-amount)))
      error-val (err error-val))))

;; Read-only functions
(define-read-only (get-will-details (testator principal))
  (match (map-get? digital-wills testator)
    will-data (ok will-data)
    (err err-will-not-found)))

(define-read-only (get-will-assets (testator principal))
  (ok (default-to u0 (map-get? will-assets testator))))

(define-read-only (get-total-wills)
  (ok (var-get total-wills)))

(define-read-only (get-contract-fee)
  (ok (var-get contract-fee)))

(define-read-only (get-contract-balance)
  (ok (stx-get-balance (as-contract tx-sender))))

;; Owner functions
(define-public (set-contract-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set contract-fee new-fee)
    (ok true)))

(define-public (withdraw-fees (amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> amount u0) err-invalid-amount)
    (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
    (ok true)))