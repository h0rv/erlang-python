// Property: each application payload copy has its own charged, single-use ingress right.
// This models encoded request ownership, not network/caller buffers, decoded objects or RSS.
abstract sig Phase {}
one sig Empty, Reserved, Claimed, Unknown, Enqueued, Queued, Running,
        Finally, Reaping, Done extends Phase {}
abstract sig Location {}
one sig Outside, Transit, Mailbox, Held extends Location {}
sig Generation {}
sig Job { size: one Int, var phase: one Phase, var generation: one Generation }
sig Copy { request: one Job, issued: one Generation, var location: one Location }
one sig Recipient { var current: one Generation }
fun charged: set Job { {j: Job | j.phase != Empty} }
fun application: set Copy { {c: Copy | c.location != Outside} }
pred bounded_sizes { all j: Job | j.size in 1 + 2 }
pred init { all j: Job | j.phase = Empty
            all c: Copy | c.location = Outside }
pred unchanged_except[j: Job] {
  all k: Job - j | k.phase' = k.phase and k.generation' = k.generation
  j.generation' = j.generation
  Recipient.current' = Recipient.current
}
pred reserve[j: Job] {
  j.phase = Empty and #charged < 2
  (sum k: charged | k.size).plus[j.size] <= 3
  j.phase' = Reserved and j.generation' = Recipient.current
  all k: Job - j | k.phase' = k.phase and k.generation' = k.generation
  location' = location and Recipient.current' = Recipient.current
}
pred claim[j: Job] {
  j.phase = Reserved and j.generation = Recipient.current
  j.phase' = Claimed and unchanged_except[j] and location' = location
}
pred handoff[j: Job, c: Copy] {
  j.phase = Claimed and c.request = j and c.location = Outside
  c.issued = j.generation and c.issued = Recipient.current
  j.phase' = Enqueued and unchanged_except[j]
  c.location' = Transit
  all d: Copy - c | d.location' = d.location
}
pred deliver[j: Job, c: Copy] {
  j.phase = Enqueued and c.request = j and c.location = Transit
  phase' = phase and generation' = generation and Recipient.current' = Recipient.current
  c.location' = Mailbox
  all d: Copy - c | d.location' = d.location
}
pred receive_payload[j: Job, c: Copy] {
  j.phase = Enqueued and c.request = j and c.location = Mailbox
  j.phase' = Queued and unchanged_except[j]
  c.location' = Held
  all d: Copy - c | d.location' = d.location
}
pred advance[j: Job] {
  (j.phase = Queued and j.phase' = Running)
  or (j.phase = Running and j.phase' = Finally)
  or (j.phase = Finally and j.phase' = Reaping)
  or (j.phase = Reaping and j.phase' = Done)
  or (j.phase = Claimed and j.phase' = Unknown)
  unchanged_except[j] and location' = location
}
pred expire[j: Job] {
  j.phase = Reserved and j.phase' = Empty
  unchanged_except[j] and location' = location
}
pred ack[j: Job] {
  j.phase = Done and j.generation = Recipient.current and j.phase' = Empty
  unchanged_except[j]
  all c: Copy | c.request = j implies c.location' = Outside else c.location' = c.location
}
pred loss {
  phase' = phase and generation' = generation
  location' = location and Recipient.current' = Recipient.current
}
pred restart {
  Recipient.current' != Recipient.current
  all j: Job | j.phase' = Empty and j.generation' = j.generation
  all c: Copy | c.location' = Outside
}
pred safe_step {
  (some j: Job | reserve[j] or claim[j] or advance[j] or expire[j] or ack[j]
    or (some c: Copy | handoff[j,c] or deliver[j,c] or receive_payload[j,c])) or loss or restart
}
// Old request/1 enqueues before checking phase. Multiple handles can copy the same token.
pred unsafe_enqueue[j: Job, c: Copy] {
  j.phase = Reserved and c.request = j and c.location = Outside
  phase' = phase and generation' = generation and Recipient.current' = Recipient.current
  c.location' = Mailbox
  all d: Copy - c | d.location' = d.location
}
pred unsafe_step {
  safe_step or (some j: Job, c: Copy | unsafe_enqueue[j,c])
}
pred bounded {
  #charged <= 2 and (sum j: charged | j.size) <= 3
  #application <= #charged
  (sum c: application | c.request.size) <= (sum j: charged | j.size)
  all j: Job | lone {c: application | c.request = j}
  all c: application | c.request in charged
}
assert old_enqueue_is_bounded {
  (bounded_sizes and init and always unsafe_step) implies always bounded
}
assert claimed_ingress_is_bounded {
  (bounded_sizes and init and always safe_step) implies always bounded
}
assert ownership_survives_loss_and_completion {
  (bounded_sizes and init and always safe_step) implies always
    (all j: Job | (j.phase in Claimed + Unknown + Enqueued + Queued + Running + Finally + Reaping
      and Recipient.current' = Recipient.current) implies j.phase' != Empty)
}
assert stale_cannot_enqueue {
  (bounded_sizes and init and always safe_step) implies always
    (all c: Copy | c.location = Outside and c.issued != Recipient.current
      and Recipient.current' = Recipient.current implies c.location' not in Transit + Mailbox)
}
check old_enqueue_is_bounded for 3 but exactly 2 Generation, 8 steps expect 1
run old_three_copies {
  bounded_sizes and init and always unsafe_step
  eventually (#charged = 1 and #application = 3
    and (sum c: application | c.request.size) = 6)
} for 3 but exactly 1 Job, exactly 3 Copy, exactly 2 Generation, 8 steps expect 1
check claimed_ingress_is_bounded for 3 but exactly 2 Generation, 12 steps expect 0
check ownership_survives_loss_and_completion for 3 but exactly 2 Generation, 12 steps expect 0
check stale_cannot_enqueue for 3 but exactly 2 Generation, 12 steps expect 0
run stale_handle_against_live_claim {
  bounded_sizes and init and always safe_step
  eventually (some c: Copy | c.issued != Recipient.current and c.location = Outside
    and c.request.phase = Claimed)
} for 3 but exactly 2 Generation, 8 steps expect 1
run { bounded_sizes and init and always safe_step and eventually (some j: Job | j.phase = Done) }
  for 3 but exactly 2 Generation, 12 steps expect 1
run { bounded_sizes and init and always safe_step and eventually (some j: Job | j.phase = Unknown) }
  for 3 but exactly 2 Generation, 8 steps expect 1
