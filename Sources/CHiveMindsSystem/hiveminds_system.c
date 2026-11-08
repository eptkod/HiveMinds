#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "hiveminds_system.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#include <sys/syscall.h>
#endif

static int set_flags(int fd) {
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) return errno;
    int fd_fl = fcntl(fd, F_GETFD);
    if (fd_fl < 0 || fcntl(fd, F_SETFD, fd_fl | FD_CLOEXEC) < 0) return errno;
    return 0;
}

int hiveminds_spawn_pty(const char *path, char *const argv[], char *const envp[], const char *cwd,
                        unsigned short rows, unsigned short cols, int *master, pid_t *pid) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_row = rows;
    ws.ws_col = cols;
    int m = -1, s = -1;
    if (openpty(&m, &s, NULL, NULL, &ws) != 0) return errno;
    int err = set_flags(m);
    if (err) { close(m); close(s); return err; }

    // The child reports a failed chdir or exec through this pipe; a successful exec closes it.
    int report[2];
    if (pipe(report) != 0) { err = errno; close(m); close(s); return err; }
    // Keep both ends above the standard descriptors, which the child replaces, even if ours were closed.
    for (int i = 0; i < 2; i++) {
        int high = fcntl(report[i], F_DUPFD_CLOEXEC, 10);
        if (high < 0) { err = errno; close(m); close(s); close(report[0]); close(report[1]); return err; }
        close(report[i]);
        report[i] = high;
    }

    // Worked out before fork: the highest descriptor to close in the child.
    struct rlimit rl;
    int max_fd = 65536;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur < (rlim_t)max_fd) max_fd = (int)rl.rlim_cur;

    pid_t child = fork();
    if (child < 0) {
        err = errno;
        close(m); close(s); close(report[0]); close(report[1]);
        return err;
    }
    if (child == 0) {
        // Child: async-signal-safe calls only.
        sigset_t all;
        sigemptyset(&all);
        sigprocmask(SIG_SETMASK, &all, NULL);
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig != SIGKILL && sig != SIGSTOP) signal(sig, SIG_DFL);
        }
        if (setsid() < 0) goto fail;
        if (ioctl(s, TIOCSCTTY, 0) < 0) goto fail;
        if (dup2(s, 0) < 0 || dup2(s, 1) < 0 || dup2(s, 2) < 0) goto fail;
        if (dup2(report[1], 3) < 0) goto fail;
        fcntl(3, F_SETFD, FD_CLOEXEC);
#ifdef __linux__
        if (syscall(SYS_close_range, 4U, ~0U, 0) != 0)
#endif
        for (int fd = 4; fd < max_fd; fd++) close(fd);
        if (cwd && chdir(cwd) != 0) goto fail;
        execve(path, argv, envp);
    fail: {
            int e = errno;
            ssize_t ignored = write(3, &e, sizeof e);
            (void)ignored;
            _exit(127);
        }
    }

    close(s);
    close(report[1]);
    int child_err = 0;
    ssize_t n;
    do { n = read(report[0], &child_err, sizeof child_err); } while (n < 0 && errno == EINTR);
    close(report[0]);
    if (n == (ssize_t)sizeof child_err) {
        int status;
        waitpid(child, &status, 0);
        close(m);
        return child_err ? child_err : ENOEXEC;
    }
    *master = m;
    *pid = child;
    return 0;
}

int hiveminds_pty_resize(int master, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_row = rows;
    ws.ws_col = cols;
    return ioctl(master, TIOCSWINSZ, &ws) == 0 ? 0 : errno;
}

int hiveminds_pidfd_open(pid_t pid) {
#if defined(__linux__) && defined(SYS_pidfd_open)
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    (void)pid;
    return -1;
#endif
}

int hiveminds_socket_peer_uid(int fd, uid_t *uid) {
#ifdef __APPLE__
    gid_t gid;
    return getpeereid(fd, uid, &gid) == 0 ? 0 : errno;
#else
    struct ucred cred;
    socklen_t len = sizeof cred;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return errno;
    *uid = cred.uid;
    return 0;
#endif
}

int hiveminds_spawn_detached(const char *path, char *const argv[], char *const envp[], int *out, pid_t *pid) {
    int p[2];
    if (pipe(p) != 0) return errno;
    for (int i = 0; i < 2; i++) {
        int high = fcntl(p[i], F_DUPFD_CLOEXEC, 10);
        if (high < 0) { int e = errno; close(p[0]); close(p[1]); return e; }
        close(p[i]);
        p[i] = high;
    }
    struct rlimit rl;
    int max_fd = 65536;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur < (rlim_t)max_fd) max_fd = (int)rl.rlim_cur;
    pid_t child = fork();
    if (child < 0) { int e = errno; close(p[0]); close(p[1]); return e; }
    if (child == 0) {
        sigset_t all;
        sigemptyset(&all);
        sigprocmask(SIG_SETMASK, &all, NULL);
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig != SIGKILL && sig != SIGSTOP) signal(sig, SIG_DFL);
        }
        setsid();
        int null = open("/dev/null", O_RDWR);
        if (null < 0) _exit(127);
        dup2(null, 0);
        dup2(p[1], 1);
        dup2(null, 2);
#ifdef __linux__
        if (syscall(SYS_close_range, 3U, ~0U, 0) != 0)
#endif
        for (int fd = 3; fd < max_fd; fd++) close(fd);
        execve(path, argv, envp);
        _exit(127);
    }
    close(p[1]);
    *out = p[0];
    *pid = child;
    return 0;
}

#ifdef __APPLE__
#include <net/route.h>
#else
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#endif

int hiveminds_address_watch_open(void) {
#ifdef __APPLE__
    int fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
#else
    int fd = socket(AF_NETLINK, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (fd < 0) return -1;
    struct sockaddr_nl sa;
    memset(&sa, 0, sizeof sa);
    sa.nl_family = AF_NETLINK;
    sa.nl_groups = RTMGRP_LINK | RTMGRP_IPV4_IFADDR | RTMGRP_IPV6_IFADDR;
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { close(fd); return -1; }
    return fd;
#endif
}
