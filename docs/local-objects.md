# Retained local Python objects

The explicit `py_context:eval_ref/4` and `apply_ref/5,6` operations retain Python objects instead of converting them to Erlang values. They are worker-mode operations. They do not fix or use the older ignored `return => ref` option.

`eval_ref(Ctx, Code, Bindings, Env)` evaluates an expression in the supplied process environment. Each binding has a UTF-8 binary name and a retained local reference as its value. It returns `{ok, Ref}`, `{python_error, ExceptionRef}`, or an Erlang runtime error. Evaluation itself does not await a coroutine value.

`apply_ref(Ctx, CallableRef, ArgsRef, KwargsRef, Env)` invokes the actual callable object. ArgsRef must contain a Python tuple and KwargsRef a Python dictionary. Coroutine results are awaited with the existing ErlangEventLoop driver on the existing context thread. The driver is reused rather than closed after each call, so loop-bound state can survive between calls. The final Python object is retained without passing through `py_to_term`. Python exceptions are retained with their original class, arguments, and traceback. An exception is not returned as a string or confused with process death.

## Ownership and scope

A local reference owns a strong Python reference and native references to its originating context and environment. Each queued request retains its inputs and execution environment until execution ends, even when its requester dies. The destructor releases Python references with the main interpreter GIL held. It does not use the older pyobject destructor that skips cleanup on attached threads.

References may be deliberately shared between Erlang owners using the same context. Sharing does not copy the object. Mutable Python arguments can therefore be shared explicitly. The originating namespace stays alive while a reference needs it. Owner death is not revocation of references that were explicitly handed to another owner. Different worker contexts still share an interpreter and modules, but local object references reject a different context, even in that same interpreter.

The execution environment must belong to the main interpreter. Own-GIL and isolated contexts are rejected. Reusing a reference in a replacement context is rejected. The public operations reject remote context PIDs. These references are not distributed or durable handles and do not serialize Python values. Objects without a value encoding, including a thread lock, can be retained locally.

Erlang external-term encoding of a resource token can resolve an existing live local resource. It neither encodes the Python object nor extends its lifetime. After the last resource reference is collected, decoding a saved binary cannot restore the object. No persistence or cross-node transfer contract follows from encoding a token.

## Execution and waiting

The context is busy for the complete operation, including awaits. Requests on that context are serialized. This can block other actors sharing it. Applications that explicitly create background tasks can introduce their own concurrent state access. This operation does not supervise those tasks or redefine asyncio task ownership. This prototype does not promise parallel async actors or support injection into an already running worker loop. A context started with `start_loop` rejects these operations. An async invocation also rejects an already running interpreter loop rather than creating a competing driver.

`apply_ref/6` adds a caller wait timeout. It uses a BEAM reply alias so a late reply is discarded after timeout or caller death. It does not interrupt, retry, roll back, or restore state. Accepted effects may continue. The default wait is infinite. Explicit context shutdown and application shutdown remain runtime operations, not a method cancellation protocol. Embedded native crashes are not contained.

## Thin actor prototype

`py_object_actor:start_link/4` accepts a context, a retained factory, allowed method references, and an explicit policy. Only the atom `unbounded` is accepted. All other policies fail before spawning with `admission_unavailable`. This is a deliberate native prototype escape hatch, not a production default or a bounded mailbox.

The gen_server invokes the zero-argument factory once to construct state, owns a process environment, and validates that allowed references are async instance members of the resulting state class. Inherited overrides are resolved before membership is accepted. Calls contain the registered native method reference, a retained argument tuple, and a retained keyword dictionary. The server adds its state as the receiver and waits for the full native invocation before accepting another call. Application method names are not sent as dispatch strings.

Method errors return the retained Python exception and leave existing state as it is. A caller timeout does not stop the method. Killing the actor can leave its already accepted coroutine running until completion. Native references retain that execution's state during the remaining work. The tests check that state is collectible after completion. Exceptions or results deliberately retained elsewhere may extend object and namespace lifetime.

An actor borrows and monitors its context. Stopping the actor does not stop the borrowed context. This module supplies no supervisor, discovery mechanism, restart policy, or automatic retry. A restarted actor has a different PID and fresh factory state. Existing PID references remain stale. Ordinary Erlang messages sent outside the actor API are not bounded or filtered by an admission scheme.

## Verification and remaining work

The native suite checks retained object identity and byte/string distinction. It checks async results and original Python exceptions. It also checks context and interpreter rejection, source-owner death, caller timeout, caller death, resource collection, token expiry, separate actor instances, concurrent increments, actor death during an await, method registration, and rejection of bounded policies.

These tests were executed through exported Common Test suite functions in disposable VMs built from this worktree. The Common Test runner was not used.

The Python-facing generic actor reference is not connected yet. A native Python call/result boundary is still needed before Beamthon can return a concrete typed reference. Beamthon must not convert the retained result through the existing lossy callback response parser. Native shared admission tickets belong to the separate safety work and are not implemented by this module.
