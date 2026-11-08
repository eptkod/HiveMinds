#include "hiveminds_dnssd.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>

#ifdef __APPLE__
#include <dns_sd.h>
#define HM_REGISTER DNSServiceRegister
#define HM_SOCKFD DNSServiceRefSockFD
#define HM_PROCESS DNSServiceProcessResult
#define HM_DEALLOC DNSServiceRefDeallocate
static int load(char *err, size_t err_len) { (void)err; (void)err_len; return 0; }
#else
#include <dlfcn.h>
// The parts of dns_sd.h we use, as Avahi's compatibility library provides them.
typedef struct _DNSServiceRef_t *DNSServiceRef;
typedef uint32_t DNSServiceFlags;
typedef int32_t DNSServiceErrorType;
typedef void (*DNSServiceRegisterReply)(DNSServiceRef, DNSServiceFlags, DNSServiceErrorType,
                                        const char *, const char *, const char *, void *);
typedef DNSServiceErrorType (*register_fn)(DNSServiceRef *, DNSServiceFlags, uint32_t, const char *, const char *,
                                           const char *, const char *, uint16_t, uint16_t, const void *,
                                           DNSServiceRegisterReply, void *);
typedef int (*sockfd_fn)(DNSServiceRef);
typedef DNSServiceErrorType (*process_fn)(DNSServiceRef);
typedef void (*dealloc_fn)(DNSServiceRef);
static register_fn HM_REGISTER;
static sockfd_fn HM_SOCKFD;
static process_fn HM_PROCESS;
static dealloc_fn HM_DEALLOC;

static int load(char *err, size_t err_len) {
    if (HM_REGISTER) return 0;
    // Avahi prints a warning about the compatibility layer unless told not to.
    setenv("AVAHI_COMPAT_NOWARN", "1", 1);
    void *lib = dlopen("libdns_sd.so.1", RTLD_NOW);
    if (!lib) lib = dlopen("libdns_sd.so", RTLD_NOW);
    if (!lib) {
        snprintf(err, err_len, "Avahi's libdns_sd isn't installed (on Arch and CachyOS it comes with the avahi package)");
        return -1;
    }
    HM_REGISTER = (register_fn)dlsym(lib, "DNSServiceRegister");
    HM_SOCKFD = (sockfd_fn)dlsym(lib, "DNSServiceRefSockFD");
    HM_PROCESS = (process_fn)dlsym(lib, "DNSServiceProcessResult");
    HM_DEALLOC = (dealloc_fn)dlsym(lib, "DNSServiceRefDeallocate");
    if (!HM_REGISTER || !HM_SOCKFD || !HM_PROCESS || !HM_DEALLOC) {
        HM_REGISTER = NULL;
        snprintf(err, err_len, "libdns_sd is missing functions HiveMinds needs");
        return -1;
    }
    return 0;
}
#endif

struct hm_service {
    DNSServiceRef ref;
    char name[256];
};

static void registered(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType error,
                       const char *name, const char *type, const char *domain, void *context) {
    (void)ref; (void)flags; (void)type; (void)domain;
    struct hm_service *s = context;
    if (error == 0 && name) {
        strncpy(s->name, name, sizeof s->name - 1);
        s->name[sizeof s->name - 1] = 0;
    }
}

int hiveminds_dnssd_register(const char *name, const char *type, uint16_t port,
                             const unsigned char *txt, uint16_t txt_len,
                             void **ref, int *fd, char *err, size_t err_len) {
    if (load(err, err_len) != 0) return -1;
    struct hm_service *s = calloc(1, sizeof *s);
    if (!s) { snprintf(err, err_len, "out of memory"); return -1; }
    DNSServiceErrorType e = HM_REGISTER(&s->ref, 0, 0, name, type, NULL, NULL, htons(port), txt_len, txt, registered, s);
    if (e != 0) {
        snprintf(err, err_len, "the mDNS daemon refused the announcement (error %d); is %s running?", (int)e,
#ifdef __APPLE__
                 "mDNSResponder"
#else
                 "avahi-daemon"
#endif
        );
        free(s);
        return (int)e;
    }
    *ref = s;
    *fd = HM_SOCKFD(s->ref);
    return 0;
}

int hiveminds_dnssd_process(void *ref) {
    struct hm_service *s = ref;
    return (int)HM_PROCESS(s->ref);
}

const char *hiveminds_dnssd_registered_name(void *ref) {
    return ((struct hm_service *)ref)->name;
}

void hiveminds_dnssd_stop(void *ref) {
    struct hm_service *s = ref;
    if (!s) return;
    HM_DEALLOC(s->ref);
    free(s);
}
