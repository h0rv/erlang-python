# Invocation admission boundary

This is the runtime contract needed by the explicit mailbox policy in Beamthon. It is a source review of `150e1cf`, not a native proof. No runtime defaults or behavior changed. No bounded invocation mailbox is implemented.

## Existing contracts

`src/py_channel.erl` defaults to `max_size = 0`, meaning unlimited. In `c_src/py_channel.c`, `nif_channel_send` encodes a term with `enif_term_to_binary`. `channel_send_owned_binary` checks queued bytes under the channel mutex before enqueue and returns `busy` on overflow. The raw byte channel counts raw payload bytes instead. Serialization happens before the check, so even that byte bound is not an allocation bound.

`channel_try_receive` and `channel_receive_blocking` subtract bytes on dequeue. Running work is no longer counted. There is no invocation-count bound. `nif_channel_create` records the creator PID but does not monitor it. A channel allows one registered waiter, not a bounded collection of pending senders. `priv/_erlang_impl/_channel.py` also documents that receive cancellation can lose an already consumed delivery. None of these contracts supplies an invocation reservation held until completion.

`src/py_event_loop.erl` calls `submit_task` or `submit_task_with_env` directly. In `c_src/py_event_loop.c`, both serialize a task and append to `loop->task_queue` under its mutex without an admission limit. Coalescing `task_ready` wakeups reduces notification traffic but does not bound queued tasks. `MAX_TASK_BATCH` limits one drain batch, not queued or running invocations.

`nif_process_ready_tasks` removes tasks from the native queue before executing them. Synchronous results, coroutine scheduling, lookup errors, allocation failures, and conversion failures take different paths. Coroutines report through `_run_and_send` in `priv/_erlang_impl/_loop.py`. A missing or dead result recipient is not proof that execution stopped. `py_event_loop:await/2` only receives a result or returns timeout. It does not cancel submitted work.

`src/py_context_embedded.erl` monitors the worker-loop owner and requests loop shutdown on owner death. This is useful lifecycle support, but not an admission lease or a per-invocation completion signal.

## Why no generic counter wrapper was added

The required invariant is that every accepted queued or running invocation owns exactly one reservation until work ends, shared by all references to its destination. Both invocation count and encoded request bytes must be reserved before enqueue.

A receiver-side check happens too late to protect its BEAM mailbox. A Python semaphore per handle is not shared across callers. Using a bounded channel as a token pool returns space at receive, too early for running work. Using OTP atomics for shared credits still leaves an ownership transfer gap.

For example, a caller reserves a credit and dies before enqueue. Without a runtime-owned association between reservation and work, the credit leaks. Returning credit when the caller dies is unsafe if enqueue already happened and work still runs. Completion can also race with cleanup and release twice. Monitoring the destination does not resolve caller ownership transfer, and process death need not stop native work immediately. A restarted owner must not reuse credits from its previous generation.

A correct implementation needs one runtime-owned reservation lifecycle connected to enqueue, every start-failure path, synchronous return, coroutine completion, and shutdown. It must not depend on a live caller receiving the reply. This review did not establish such a primitive from the current channel, task, or atomics interfaces. No dispatcher, manager, scheduler, or new supervision framework was added to hide the gap.

## Contract for a future implementation

The Python policy is the immutable closed union `BoundedMailbox(capacity=128, max_bytes=...) | UnboundedMailbox()`. Both bounded arguments are required positive integers. Capacity means queued plus running invocations. Bytes mean actual encoded request payload lengths retained as a charge until work ends, not an exact memory guarantee. There is only immediate rejection on overload, with `MailboxOverloaded` meaning rejection before enqueue. There is no drop, retry, or unbounded queue of waiting submitters.

A future native implementation must demonstrate these cases before a safe API accepts a bounded policy:

* Concurrent references and callers share one destination limit. Count and bytes are reserved together before enqueue. An oversized request does not enqueue.
* Serialization or enqueue failure returns reservations once. Rejection leaves no accepted invocation.
* Reply timeout, receive cancellation, and caller death retain reservations for work still running.
* Failure to start work, ordinary return, Python exceptions, and coroutine cancellation release once after execution ends. Failed result delivery cannot leak reservations.
* Owner death and shutdown close admission. Queued and running work cannot outlive released credits. Work accepted during a shutdown race is either rejected or remains charged until it ends.
* Restart uses a fresh admission identity. Late completions from an old owner cannot change the new owner's credits.

The invocation guarantee applies only to requests made through the enforcing library API. Trusted raw Erlang sends can bypass admission. Control messages and result mailboxes are outside the request limit. Native crashes remain capable of terminating the VM. Native integration tests and an audited ownership protocol are still required. No build or runtime tests were run for this documentation-only runtime change.
