// Credits survive waiter loss and disconnect until body cleanup and explicit observation.
abstract sig Phase {}
one sig Empty, Reserved, Accepted, Done extends Phase {}
sig Job { size: one Int, var phase: one Phase, var generation: one Generation }
sig Generation {}
one sig Recipient { var current: one Generation }

fun held: set Job { {j: Job | j.phase != Empty} }
pred bounded_sizes { all j: Job | j.size = 1 or j.size = 2 }
pred init { all j: Job | j.phase = Empty and j.generation = Recipient.current }
pred step {
  (some j: Job | {
    (j.phase = Empty and #held < 2 and (sum k: held | k.size).plus[j.size] <= 3
      and j.phase' = Reserved and j.generation' = Recipient.current)
    or (j.phase = Reserved and j.generation = Recipient.current and j.phase' = Accepted and j.generation' = j.generation)
    or (j.phase = Reserved and j.phase' = Empty and j.generation' = j.generation)
    or (j.phase = Accepted and j.phase' = Done and j.generation' = j.generation)
    or (j.phase = Done and j.generation = Recipient.current and j.phase' = Empty and j.generation' = j.generation)
    all k: Job - j | k.phase' = k.phase and k.generation' = k.generation
    Recipient.current' = Recipient.current
  })
  or { // Loss, waiter timeout, and cancelled observation cannot release work.
    phase' = phase
    generation' = generation
    Recipient.current' = Recipient.current
  }
  or { // A new VM has empty state; old tokens never address its new generation.
    Recipient.current' != Recipient.current
    all j: Job | j.phase' = Empty and j.generation' = Recipient.current'
  }
}
pred behavior { bounded_sizes and init and always step }
assert admission_bounds {
  behavior implies always (#held <= 2 and (sum k: held | k.size) <= 3)
}
check admission_bounds for 3 but 8 steps expect 0
assert held_until_body_done {
  behavior implies always (all j: Job |
    (j.phase = Accepted and Recipient.current' = Recipient.current) implies
      j.phase' in Accepted + Done)
}
assert stale_cannot_start {
  behavior implies always (all j: Job |
    (j.phase = Reserved and j.generation != Recipient.current) implies j.phase' != Accepted)
}
check held_until_body_done for 3 but 8 steps expect 0
check stale_cannot_start for 3 but 8 steps expect 0
run { behavior and eventually (some j: Job | j.phase = Done) } for 3 but 8 steps expect 1
run { behavior and eventually Recipient.current != Recipient.current' } for 3 but 8 steps expect 1
