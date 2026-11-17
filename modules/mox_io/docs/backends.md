# Native backends

## IOCP

Winsock uses pinned overlapped contexts and cached AcceptEx/ConnectEx functions. Files use explicit-offset overlapped ReadFile/WriteFile. GetQueuedCompletionStatusEx harvests batches and maps each NTSTATUS independently.

Synchronous success still awaits its packet. Immediate failures produce no packet; immediate file EOF completes locally. CancelIoEx retains its context until the corresponding packet arrives.

Accept/connect update socket contexts before public success. Open, metadata, sync, and enabled file close run on bounded workers. Valid UTF-8 paths convert into fixed UTF-16 scratch. Wake packets are coalesced.

## epoll

Independent x86_64/aarch64 syscall bindings provide Linux sockets, epoll, eventfd, and file I/O. epoll_event is packed to 12 bytes on x86_64 and naturally aligned to 16 bytes on aarch64. Sockets are nonblocking and close-on-exec.

Read interest uses EPOLLET and EPOLLRDHUP. Write interest exists only for pending send/connect. Immediate syscall attempts avoid losing edges received before admission.

The readiness engine consumes native batches before reuse and removes queued nodes at detach. Broken watch updates terminate affected requests. Connect cancellation records socket retirement to prevent closing a reused descriptor number.

Files use bounded workers and statx metadata. Linux consumes a close descriptor even when final writeback reports an error.

## io_uring

Setup probes required features and opcodes. Optional single-issuer/cooperative flags fall back to baseline setup when unsupported.

SQ/CQ and SQEs map directly. Release publishes SQEs before the tail; acquire observes CQEs before copying. Capacity accounts for operations, cancellations, resource closes, and wake requests. NODROP is required.

TCP, UDP, reads, writes, sync, and close use native SQEs. UDP message headers and iovecs remain pinned. Open/metadata use workers. One-shot eventfd poll provides wakeup.

Tagged pointers distinguish primary/cancel/wake CQEs. Reuse waits for primary plus any cancellation CQE, preventing an old cancel from matching a new request at the same address.

Set `Options.uring_fixed_files = true` to register a fixed table with one slot per
resource. Unsupported or policy-disabled registration falls back to ordinary
descriptors; resource exhaustion remains an error. Other backends ignore this
option. It defaults to false because registration adds setup/close syscalls and
only benefits operations submitted through the ring, not direct TCP fast paths.

`loop.stats().native.fixed_file_capacity` reports the active table capacity (zero
when disabled or unavailable), `registered_files` counts retained references,
and `fixed_file_submissions` counts SQEs that use those references. Detach removes
the registration after all operations using it finish and before closing the ordinary fd.
A failed removal retains the registration and descriptor for close retry. The table uses fixed user
storage; kernel registration allocations are not included in `kernel_mapped_bytes`.

Registered buffers, SQPOLL, multishot operations, and zero-copy sends are not enabled.

## kqueue

The shared readiness engine uses independent Darwin/FreeBSD bindings: 32-byte Darwin kevent, 64-byte FreeBSD 12+ kevent, and platform-specific EVFILT_USER numbers.

EV_CLEAR handles readiness. Write filters exist only while needed. EV_RECEIPT collects change failures synchronously. EVFILT_USER coalesces wakes without another descriptor.

BSD/Darwin sockaddr carries leading length/family bytes. Darwin uses SO_NOSIGPIPE; FreeBSD uses MSG_NOSIGNAL. UDP recvmsg preserves truncation.

Files use bounded workers and native stat structures. Cross-compilation checks ABI/code generation. Real macOS and FreeBSD native suites establish runtime validation.

## Runtime boundary

Library imports are compiler builtin metadata and local modules. The optional Boot helper installs an entry, panic handlers, memory helpers, and Windows stack probing. Other runtimes can import the library without installing those symbols.

POSIX uses system C startup/pthread APIs. Windows programs using Boot select its custom entry and call OS DLLs.
