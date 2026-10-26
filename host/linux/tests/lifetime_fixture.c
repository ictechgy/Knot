/* SPDX-License-Identifier: GPL-3.0-only */
/* Inert native fixture: fresh marker files only; no desktop, devices or network. */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static atomic_int thread_ran;
static void *worker(void *unused) {
    (void) unused;
    atomic_store(&thread_ran, 1);
    return NULL;
}

static int denied(FILE *report, const char *name, long number, unsigned long argument) {
    errno = 0;
    long result = syscall(number, argument, 0, 0, 0, 0, 0);
    int error = errno;
    /* Never leave an inert child behind if enforcement regresses. */
    if ((number == SYS_fork || number == SYS_vfork || number == SYS_clone) && result >= 0) {
        if (result == 0) _exit(97);
        waitpid((pid_t) result, NULL, 0);
    }
    fprintf(report, "%s=%d\n", name, result == -1 ? error : 0);
    return result == -1 && error == EPERM ? 0 : 1;
}

static int probe(const char *path) {
    FILE *report = fopen(path, "w");
    if (!report) return 2;
    int failed = 0;
    failed |= denied(report, "fork", SYS_fork, 0);
    failed |= denied(report, "vfork", SYS_vfork, 0);
    failed |= denied(report, "clone_process", SYS_clone, SIGCHLD);
    failed |= denied(report, "clone_vm_process", SYS_clone, CLONE_VM | SIGCHLD);
    /* These invalid/high flags must be refused by our filter, before the
       kernel can reject them with EINVAL or use any supplied child stack. */
    failed |= denied(report, "clone_parent", SYS_clone, 0x003d0f00UL | CLONE_PARENT);
    failed |= denied(report, "clone_namespace", SYS_clone, 0x003d0f00UL | CLONE_NEWUSER);
    failed |= denied(report, "clone_high_word", SYS_clone, 0x1003d0f00UL);
    failed |= denied(report, "setpgid", SYS_setpgid, 0);
    failed |= denied(report, "setsid", SYS_setsid, 0);
    failed |= denied(report, "unshare", SYS_unshare, 0);
    failed |= denied(report, "setns", SYS_setns, (unsigned long) -1);
    errno = 0;
    long clone3 = syscall(SYS_clone3, NULL, 0);
    int clone3_error = errno;
    fprintf(report, "clone3=%d\n", clone3 == -1 ? clone3_error : 0);
    failed |= clone3 != -1 || clone3_error != ENOSYS;
    pthread_t thread;
    int status = pthread_create(&thread, NULL, worker, NULL);
    if (!status) status = pthread_join(thread, NULL);
    fprintf(report, "pthread=%d\n", !status && atomic_load(&thread_ran));
    failed |= status || !atomic_load(&thread_ran);
    fprintf(report, "pid=%ld\npgid=%ld\n", (long) getpid(), (long) getpgrp());
    fclose(report);
    return failed ? 3 : 0;
}

static int forbid_install_and_exec(char **command) {
    /* Simulate an environment whose policy rejects installing our filter.
       The supervisor must refuse launch rather than use a group-only fallback. */
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_prctl, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, PR_SET_SECCOMP, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = {sizeof(instructions) / sizeof(instructions[0]), instructions};
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) return 4;
    execv(command[0], command);
    return 5;
}

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "forbid-install-exec")) return forbid_install_and_exec(argv + 2);
    if (argc != 3) return 1;
    if (!strcmp(argv[1], "probe")) return probe(argv[2]);
    /* Match the pinned upstream restart's first step: fork must fail before a
       child can call setsid and exec. No real host/driver is executed here. */
    int restart_error = 0;
    if (!strcmp(argv[1], "restart")) {
        errno = 0;
        pid_t child = fork();
        restart_error = errno;
        if (child == 0) _exit(97);
        if (child > 0) { waitpid(child, NULL, 0); return 6; }
        if (restart_error != EPERM) return 7;
    } else if (strcmp(argv[1], "hold") && strcmp(argv[1], "stubborn")) return 1;
    if (!strcmp(argv[1], "stubborn")) signal(SIGTERM, SIG_IGN);
    pthread_t thread;
    int status = pthread_create(&thread, NULL, worker, NULL);
    if (status || pthread_join(thread, NULL) || !atomic_load(&thread_ran)) return 8;
    for (unsigned long beat = 1; ; ++beat) {
        FILE *report = fopen(argv[2], "w");
        if (!report) return 2;
        fprintf(report, "pid=%ld\npgid=%ld\nbeat=%lu\nrestart=%d\npthread=1\n",
                (long) getpid(), (long) getpgrp(), beat, restart_error);
        fclose(report);
        usleep(20000);
    }
}
