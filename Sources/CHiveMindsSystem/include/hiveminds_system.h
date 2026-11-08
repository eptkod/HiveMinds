// The few system calls HiveMinds needs from C: starting a program in a new pseudo-terminal (the child, between
// fork and exec, may only make async-signal-safe calls), and checking who is at the other end of a Unix socket
// (Linux's `struct ucred` needs _GNU_SOURCE, which Swift doesn't see).
#ifndef HIVEMINDS_SYSTEM_H
#define HIVEMINDS_SYSTEM_H

#include <sys/types.h>

/// Starts `path` with `argv` and `envp` (NULL-terminated) in a new session whose controlling terminal is a
/// new pseudo-terminal of `rows` x `cols`, in `cwd` (may be NULL). In the child, every descriptor above 2 is
/// closed and all signals go back to their defaults and are unblocked, so the program gets nothing of ours.
/// On success returns 0, sets `*master` (non-blocking, close-on-exec) and `*pid`. On failure returns an errno
/// value: from opening the terminal, from fork, or from chdir/exec in the child (reported back through a pipe).
int hiveminds_spawn_pty(const char *path, char *const argv[], char *const envp[], const char *cwd,
                        unsigned short rows, unsigned short cols, int *master, pid_t *pid);

/// Sets the terminal size. Returns 0 or an errno value.
int hiveminds_pty_resize(int master, unsigned short rows, unsigned short cols);

/// Linux: a pidfd for `pid` (readable once the process exits), or -1. Elsewhere always -1.
int hiveminds_pidfd_open(pid_t pid);

/// Starts `path` in a new session with no controlling terminal: stdin and stderr are /dev/null, stdout is the
/// pipe returned in `*out` (close-on-exec in the parent). Everything else is closed and signals are reset, as above.
/// For running the user's interactive login shell to read its PATH: with a terminal it would try to take it over,
/// and be stopped (SIGTTIN/SIGTTOU) when we're running in one. Returns 0 or an errno value.
int hiveminds_spawn_detached(const char *path, char *const argv[], char *const envp[], int *out, pid_t *pid);

/// A non-blocking socket that becomes readable whenever this machine's network addresses or interfaces change
/// (a routing socket on macOS, netlink on Linux). Read and discard what arrives, then look at the addresses again.
/// Returns -1 when it can't be opened.
int hiveminds_address_watch_open(void);

/// The user id of the process at the other end of a connected Unix socket. Returns 0 or an errno value.
int hiveminds_socket_peer_uid(int fd, uid_t *uid);

#endif
