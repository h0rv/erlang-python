open distribution

pred unsafe_timeout {
  some j: Job | {
    j.phase = Accepted
    j.phase' = Empty
    j.generation' = j.generation
    all k: Job - j | k.phase' = k.phase and k.generation' = k.generation
    Recipient.current' = Recipient.current
  }
}
assert early_release_breaks_ownership {
  (bounded_sizes and init and always (step or unsafe_timeout)) implies
    always (all j: Job |
      (j.phase = Accepted and Recipient.current' = Recipient.current) implies
        j.phase' in Accepted + Done)
}
check early_release_breaks_ownership for 3 but 8 steps expect 1
