// Announcing a service on the local network (Bonjour on macOS, Avahi on Linux) through the dns_sd API.
// On Linux, Avahi's compatibility library (libdns_sd.so.1) is loaded at run time, so the host still runs
// where it isn't installed, only without discovery.
#ifndef HIVEMINDS_DNSSD_H
#define HIVEMINDS_DNSSD_H

#include <stddef.h>
#include <stdint.h>

/// Starts announcing `name` (e.g. "hiveminds-1a2b3c4d") of `type` (e.g. "_hiveminds._tcp") on `port` (host
/// byte order), with a TXT record (`txt`, `txt_len` bytes, already in DNS TXT format). On success returns 0,
/// sets `*ref` and `*fd` (watch it for reading, then call hiveminds_dnssd_process). On failure returns a
/// non-zero code and writes a message to `err`.
int hiveminds_dnssd_register(const char *name, const char *type, uint16_t port,
                             const unsigned char *txt, uint16_t txt_len,
                             void **ref, int *fd, char *err, size_t err_len);

/// Handles what the daemon sent (call when the fd is readable). Returns 0 or a dns_sd error code.
int hiveminds_dnssd_process(void *ref);

/// The name the service ended up with (after any conflict renaming), or "" before it's confirmed.
const char *hiveminds_dnssd_registered_name(void *ref);

/// Stops announcing and frees everything.
void hiveminds_dnssd_stop(void *ref);

#endif
