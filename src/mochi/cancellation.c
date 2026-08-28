#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>

#if defined(__unix__) || defined(__APPLE__)
#include <arpa/inet.h>
#include <dirent.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#endif

enum {
    MOCHI_DEADLINE_ERROR = -1,
    MOCHI_DEADLINE_TIMEOUT = -2,
};

#if defined(__unix__) || defined(__APPLE__)
extern char **environ;

static char *mochi_copy_string(const char *value) {
    size_t length = strlen(value);
    char *copy = (char *)malloc(length + 1);
    if (copy != NULL) {
        memcpy(copy, value, length + 1);
    }
    return copy;
}

static char *mochi_resolve_executable(const char *path) {
    if (strchr(path, '/') != NULL) {
        return mochi_copy_string(path);
    }
    const char *search_path = getenv("PATH");
    if (search_path == NULL) {
        search_path = "/bin:/usr/bin";
    }
    size_t path_length = strlen(path);
    const char *cursor = search_path;
    for (;;) {
        const char *separator = strchr(cursor, ':');
        size_t directory_length = separator == NULL
            ? strlen(cursor)
            : (size_t)(separator - cursor);
        size_t prefix_length = directory_length == 0 ? 1 : directory_length;
        if (prefix_length <= SIZE_MAX - path_length - 2) {
            size_t candidate_length = prefix_length + 1 + path_length;
            char *candidate = (char *)malloc(candidate_length + 1);
            if (candidate == NULL) {
                return NULL;
            }
            if (directory_length == 0) {
                candidate[0] = '.';
            } else {
                memcpy(candidate, cursor, directory_length);
            }
            candidate[prefix_length] = '/';
            memcpy(candidate + prefix_length + 1, path, path_length + 1);
            if (access(candidate, X_OK) == 0) {
                return candidate;
            }
            free(candidate);
        }
        if (separator == NULL) {
            break;
        }
        cursor = separator + 1;
    }
    errno = ENOENT;
    return NULL;
}

int mochi_absolute_path(
    const char *path, char *resolved, size_t resolved_capacity
) {
    if (path == NULL || path[0] == '\0' || resolved == NULL ||
        resolved_capacity == 0) {
        return EINVAL;
    }
    if (path[0] == '/') {
        size_t length = strlen(path);
        if (length >= resolved_capacity) {
            return ENAMETOOLONG;
        }
        memcpy(resolved, path, length + 1);
        return 0;
    }
    if (getcwd(resolved, resolved_capacity) == NULL) {
        return errno == 0 ? EIO : errno;
    }
    size_t directory_length = strlen(resolved);
    size_t path_length = strlen(path);
    bool needs_separator =
        directory_length == 0 || resolved[directory_length - 1] != '/';
    size_t separator_length = needs_separator ? 1 : 0;
    if (directory_length > SIZE_MAX - separator_length - path_length - 1 ||
        directory_length + separator_length + path_length >=
            resolved_capacity) {
        return ENAMETOOLONG;
    }
    if (needs_separator) {
        resolved[directory_length++] = '/';
    }
    memcpy(resolved + directory_length, path, path_length + 1);
    return 0;
}

int mochi_resolve_executable_path(
    const char *path, char *resolved, size_t resolved_capacity
) {
    if (path == NULL || path[0] == '\0') {
        return EINVAL;
    }
    char *candidate = mochi_resolve_executable(path);
    if (candidate == NULL) {
        return errno == 0 ? ENOENT : errno;
    }
    int result = mochi_absolute_path(
        candidate, resolved, resolved_capacity
    );
    free(candidate);
    return result;
}

static long mochi_highest_open_descriptor(void) {
    const char *directory_path =
#if defined(__linux__)
        "/proc/self/fd";
#else
        "/dev/fd";
#endif
    DIR *directory = opendir(directory_path);
    if (directory == NULL) {
        return -1;
    }
    long highest = -1;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        long value = 0;
        const unsigned char *cursor = (const unsigned char *)entry->d_name;
        if (*cursor < '0' || *cursor > '9') {
            continue;
        }
        while (*cursor >= '0' && *cursor <= '9') {
            if (value > (LONG_MAX - (*cursor - '0')) / 10) {
                value = LONG_MAX;
                break;
            }
            value = value * 10 + (*cursor - '0');
            ++cursor;
        }
        if (*cursor == '\0' && value > highest) {
            highest = value;
        }
    }
    (void)closedir(directory);
    return highest;
}

static long mochi_descriptor_limit(void) {
    long descriptor_limit = sysconf(_SC_OPEN_MAX);
    if (descriptor_limit < 3) {
        descriptor_limit = 1024;
    }
    struct rlimit limits;
    if (getrlimit(RLIMIT_NOFILE, &limits) == 0 &&
        limits.rlim_max != RLIM_INFINITY &&
        limits.rlim_max > (rlim_t)descriptor_limit) {
        descriptor_limit = limits.rlim_max > (rlim_t)INT_MAX
            ? INT_MAX
            : (long)limits.rlim_max;
    }
    long highest = mochi_highest_open_descriptor();
    if (highest >= descriptor_limit && highest < INT_MAX) {
        descriptor_limit = highest + 1;
    }
    return descriptor_limit > INT_MAX ? INT_MAX : descriptor_limit;
}

static void mochi_child_close_from(long descriptor_limit) {
    for (
        int fd = STDERR_FILENO + 1;
        fd < (int)descriptor_limit;
        ++fd
    ) {
        while (close(fd) != 0 && errno == EINTR) {
        }
    }
}
#else
int mochi_absolute_path(
    const char *path, char *resolved, size_t resolved_capacity
) {
    (void)path;
    (void)resolved;
    (void)resolved_capacity;
    return -1;
}

int mochi_resolve_executable_path(
    const char *path, char *resolved, size_t resolved_capacity
) {
    (void)path;
    (void)resolved;
    (void)resolved_capacity;
    return -1;
}
#endif

int mochi_spawn_process(
    const char *path,
    char *const argv[],
    int stdin_fd,
    int stdout_fd,
    int stderr_fd
) {
#if defined(__unix__) || defined(__APPLE__)
    if (path == NULL || path[0] == '\0' || argv == NULL || argv[0] == NULL) {
        errno = EINVAL;
        return -1;
    }
    char *resolved_path = mochi_resolve_executable(path);
    if (resolved_path == NULL) {
        return -1;
    }

    /* Resolve the descriptor bound before fork: sysconf is not required to be
       async-signal-safe, while close(2) is. */
    long descriptor_limit = mochi_descriptor_limit();

    pid_t pid = fork();
    if (pid < 0) {
        free(resolved_path);
        return -1;
    }
    if (pid == 0) {
        /* After fork this path is deliberately limited to POSIX
           async-signal-safe operations. */
        if (setpgid(0, 0) != 0) {
            _exit(126);
        }
        if (stdin_fd >= 0 && stdin_fd != STDIN_FILENO &&
            dup2(stdin_fd, STDIN_FILENO) < 0) {
            _exit(126);
        }
        if (stdout_fd >= 0 && stdout_fd != STDOUT_FILENO &&
            dup2(stdout_fd, STDOUT_FILENO) < 0) {
            _exit(126);
        }
        if (stderr_fd >= 0 && stderr_fd != STDERR_FILENO &&
            dup2(stderr_fd, STDERR_FILENO) < 0) {
            _exit(126);
        }
        mochi_child_close_from(descriptor_limit);
        execve(resolved_path, argv, environ);
        _exit(127);
    }
    free(resolved_path);

    /* Close the small race in which a caller cancels immediately after spawn.
       EACCES means the child has already exec'd after establishing its group;
       ESRCH means it has already exited. */
    if (setpgid(pid, pid) != 0 && errno != EACCES && errno != ESRCH) {
        int saved_error = errno;
        (void)kill(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
        }
        errno = saved_error;
        return -1;
    }
    return (int)pid;
#else
    (void)path;
    (void)argv;
    (void)stdin_fd;
    (void)stdout_fd;
    (void)stderr_fd;
    return -1;
#endif
}

int64_t mochi_deadline_after_millis(int64_t timeout_milliseconds) {
#if defined(__unix__) || defined(__APPLE__)
    if (timeout_milliseconds <= 0) {
        return -1;
    }
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    int64_t milliseconds =
        (int64_t)now.tv_sec * 1000 + (int64_t)now.tv_nsec / 1000000;
    if (timeout_milliseconds > INT64_MAX - milliseconds) {
        return INT64_MAX;
    }
    return milliseconds + timeout_milliseconds;
#else
    (void)timeout_milliseconds;
    return -1;
#endif
}

#if defined(__unix__) || defined(__APPLE__)
static int64_t mochi_monotonic_millis(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    return (int64_t)now.tv_sec * 1000 + (int64_t)now.tv_nsec / 1000000;
}

static int mochi_poll_until(int fd, short events, int64_t deadline) {
    for (;;) {
        int64_t now = mochi_monotonic_millis();
        if (now < 0) {
            return MOCHI_DEADLINE_ERROR;
        }
        if (now >= deadline) {
            return MOCHI_DEADLINE_TIMEOUT;
        }
        int64_t remaining = deadline - now;
        int timeout = remaining > INT_MAX ? INT_MAX : (int)remaining;
        struct pollfd descriptor = {
            .fd = fd,
            .events = events,
            .revents = 0,
        };
        int ready = poll(&descriptor, 1, timeout);
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready < 0) {
            return MOCHI_DEADLINE_ERROR;
        }
        if (ready == 0) {
            return MOCHI_DEADLINE_TIMEOUT;
        }
        if ((descriptor.revents & POLLNVAL) != 0) {
            return MOCHI_DEADLINE_ERROR;
        }
        if ((descriptor.revents & (events | POLLHUP)) != 0) {
            return 0;
        }
        if ((descriptor.revents & POLLERR) != 0) {
            return MOCHI_DEADLINE_ERROR;
        }
    }
}

static int mochi_make_nonblocking(int fd) {
    int flags;
    do {
        flags = fcntl(fd, F_GETFL);
    } while (flags < 0 && errno == EINTR);
    if (flags < 0) {
        return -1;
    }
    if ((flags & O_NONBLOCK) != 0) {
        return 0;
    }
    int result;
    do {
        result = fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    } while (result < 0 && errno == EINTR);
    return result;
}

static ssize_t mochi_write_without_sigpipe(
    int fd, const void *data, size_t length
) {
    sigset_t blocked;
    sigset_t previous;
    sigset_t pending;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    int mask_error = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (mask_error != 0) {
        errno = mask_error;
        return -1;
    }
    bool pipe_was_pending =
        sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE) == 1;
    ssize_t written = write(fd, data, length);
    int write_error = errno;
    bool pipe_is_pending =
        sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE) == 1;
    if (
        written < 0 && write_error == EPIPE && !pipe_was_pending &&
        pipe_is_pending
    ) {
#if defined(__APPLE__)
        int caught_signal = 0;
        (void)sigwait(&blocked, &caught_signal);
#else
        struct timespec no_wait = {.tv_sec = 0, .tv_nsec = 0};
        while (sigtimedwait(&blocked, NULL, &no_wait) < 0 && errno == EINTR) {
        }
#endif
    }
    int restore_error = pthread_sigmask(SIG_SETMASK, &previous, NULL);
    if (written >= 0 && restore_error != 0) {
        errno = restore_error;
        return -1;
    }
    errno = write_error;
    return written;
}
#endif

int mochi_fd_write_all_until(
    int fd, const void *data, size_t length, int64_t deadline
) {
#if defined(__unix__) || defined(__APPLE__)
    if (fd < 0 || data == NULL || deadline < 0 || mochi_make_nonblocking(fd) != 0) {
        return MOCHI_DEADLINE_ERROR;
    }
    size_t offset = 0;
    while (offset < length) {
        int ready = mochi_poll_until(fd, POLLOUT, deadline);
        if (ready != 0) {
            return ready;
        }
        ssize_t written = mochi_write_without_sigpipe(
            fd, (const unsigned char *)data + offset, length - offset
        );
        if (written < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        if (written <= 0) {
            return MOCHI_DEADLINE_ERROR;
        }
        offset += (size_t)written;
    }
    return 0;
#else
    (void)fd;
    (void)data;
    (void)length;
    (void)deadline;
    return MOCHI_DEADLINE_ERROR;
#endif
}

int mochi_fd_read_some_until(
    int fd, void *data, size_t capacity, int64_t deadline
) {
#if defined(__unix__) || defined(__APPLE__)
    if (fd < 0 || data == NULL || capacity == 0 || deadline < 0 ||
        mochi_make_nonblocking(fd) != 0) {
        return MOCHI_DEADLINE_ERROR;
    }
    for (;;) {
        int ready = mochi_poll_until(fd, POLLIN, deadline);
        if (ready != 0) {
            return ready;
        }
        ssize_t count = read(fd, data, capacity);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        if (count < 0 || count > INT_MAX) {
            return MOCHI_DEADLINE_ERROR;
        }
        return (int)count;
    }
#else
    (void)fd;
    (void)data;
    (void)capacity;
    (void)deadline;
    return MOCHI_DEADLINE_ERROR;
#endif
}

int mochi_process_is_alive(int pid_value) {
#if defined(__unix__) || defined(__APPLE__)
    pid_t pid = (pid_t)pid_value;
    if (pid <= 0) {
        errno = EINVAL;
        return -1;
    }
    siginfo_t child = {0};
    int observed;
    do {
        observed = waitid(
            P_PID, (id_t)pid, &child, WEXITED | WNOHANG | WNOWAIT
        );
    } while (observed != 0 && errno == EINTR);
    if (observed != 0) {
        return errno == ECHILD ? 0 : -1;
    }
    return child.si_pid == 0 ? 1 : 0;
#else
    (void)pid_value;
    return -1;
#endif
}

static int mochi_wait_process_group_gone_until(
    pid_t pid, int64_t deadline
) {
    for (;;) {
        /* When Mochi is PID 1 or a child subreaper, compiler descendants are
           adopted here. Reap them so killed zombies cannot pin the group. */
        for (;;) {
            int adopted_status = 0;
            pid_t adopted = waitpid(-pid, &adopted_status, WNOHANG);
            if (adopted > 0) {
                continue;
            }
            if (adopted < 0 && errno == EINTR) {
                continue;
            }
            break;
        }
        if (kill(-pid, 0) != 0) {
            if (errno == ESRCH) {
                return 0;
            }
            if (errno != EPERM) {
                return MOCHI_DEADLINE_ERROR;
            }
        }
        int64_t now = mochi_monotonic_millis();
        if (now < 0) {
            return MOCHI_DEADLINE_ERROR;
        }
        if (now >= deadline) {
            return MOCHI_DEADLINE_TIMEOUT;
        }
        int64_t remaining = deadline - now;
        struct timespec pause = {
            .tv_sec = 0,
            .tv_nsec = (long)(remaining < 10 ? remaining : 10) * 1000000L,
        };
        if (nanosleep(&pause, NULL) != 0 && errno != EINTR) {
            return MOCHI_DEADLINE_ERROR;
        }
    }
}

static int mochi_kill_and_reap_owned_process_group(
    pid_t pid, int *status, int64_t drain_deadline
) {
    int signal_error = 0;
    if (kill(-pid, SIGKILL) != 0 && errno != ESRCH) {
        signal_error = errno == 0 ? EIO : errno;
    }
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH && signal_error == 0) {
        signal_error = errno == 0 ? EIO : errno;
    }
    int local_status = 0;
    pid_t waited;
    do {
        waited = waitpid(pid, &local_status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != pid) {
        return MOCHI_DEADLINE_ERROR;
    }
    if (status != NULL) {
        *status = local_status;
    }
    if (signal_error != 0) {
        errno = signal_error;
        return MOCHI_DEADLINE_ERROR;
    }
    return mochi_wait_process_group_gone_until(pid, drain_deadline);
}

int mochi_kill_process_group_and_wait(int pid_value, int *status) {
#if defined(__unix__) || defined(__APPLE__)
    pid_t pid = (pid_t)pid_value;
    if (pid <= 0) {
        return -1;
    }
    /* Establish that PID still names our unreaped child before signaling its
       process group. This prevents a stale numeric PID/PGID from targeting an
       unrelated process after reuse. */
    siginfo_t child = {0};
    int observed;
    do {
        observed = waitid(
            P_PID, (id_t)pid, &child, WEXITED | WNOHANG | WNOWAIT
        );
    } while (observed != 0 && errno == EINTR);
    if (observed != 0) {
        return -1;
    }
    int64_t drain_deadline = mochi_deadline_after_millis(1000);
    if (drain_deadline < 0) {
        return -1;
    }
    return mochi_kill_and_reap_owned_process_group(
        pid, status, drain_deadline
    ) == 0 ? 0 : -1;
#else
    (void)pid_value;
    (void)status;
    return -1;
#endif
}

int mochi_wait_process_until(int pid_value, int64_t deadline, int *status) {
#if defined(__unix__) || defined(__APPLE__)
    pid_t pid = (pid_t)pid_value;
    if (pid <= 0 || deadline < 0) {
        return -1;
    }
    for (;;) {
        /* WNOWAIT retains the exited leader as an identity anchor. Descendants
           are signaled before waitpid releases that PID/PGID for reuse. */
        siginfo_t child = {0};
        int observed;
        do {
            observed = waitid(
                P_PID, (id_t)pid, &child, WEXITED | WNOHANG | WNOWAIT
            );
        } while (observed != 0 && errno == EINTR);
        if (observed != 0) {
            return -1;
        }
        if (child.si_pid == pid) {
            return mochi_kill_and_reap_owned_process_group(
                pid, status, deadline
            );
        }
        int64_t now = mochi_monotonic_millis();
        if (now < 0) {
            (void)mochi_kill_process_group_and_wait(pid_value, status);
            return -1;
        }
        if (now >= deadline) {
            int64_t drain_deadline = mochi_deadline_after_millis(1000);
            if (drain_deadline < 0) {
                return -1;
            }
            (void)mochi_kill_and_reap_owned_process_group(
                pid, status, drain_deadline
            );
            return 1;
        }
        int64_t remaining = deadline - now;
        struct timespec pause = {
            .tv_sec = 0,
            .tv_nsec = (long)(remaining < 10 ? remaining : 10) * 1000000L,
        };
        if (nanosleep(&pause, NULL) != 0 && errno != EINTR) {
            (void)mochi_kill_process_group_and_wait(pid_value, status);
            return -1;
        }
    }
#else
    (void)pid_value;
    (void)deadline;
    (void)status;
    return -1;
#endif
}

int mochi_copy_file(const char *source, const char *destination) {
#if defined(__unix__) || defined(__APPLE__)
    int input = open(source, O_RDONLY);
    if (input < 0) {
        return errno == 0 ? -1 : errno;
    }
    int output = open(destination, O_WRONLY | O_CREAT | O_TRUNC, 0700);
    if (output < 0) {
        int error = errno == 0 ? -1 : errno;
        close(input);
        return error;
    }
    unsigned char buffer[65536];
    for (;;) {
        ssize_t count = read(input, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count < 0) {
            int error = errno == 0 ? -1 : errno;
            close(input);
            close(output);
            return error;
        }
        if (count == 0) {
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(output, buffer + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR) {
                continue;
            }
            if (written <= 0) {
                int error = errno == 0 ? -1 : errno;
                close(input);
                close(output);
                return error;
            }
            offset += written;
        }
    }
    if (fsync(output) != 0) {
        int error = errno == 0 ? -1 : errno;
        close(input);
        close(output);
        return error;
    }
    close(input);
    close(output);
    return 0;
#else
    (void)source;
    (void)destination;
    return -1;
#endif
}

int mochi_open_readonly(const char *path) {
#if defined(__unix__) || defined(__APPLE__)
    if (path == NULL) {
        errno = EINVAL;
        return -1;
    }
    return open(path, O_RDONLY);
#else
    (void)path;
    return -1;
#endif
}

int mochi_same_file(const char *left, const char *right) {
#if defined(__unix__) || defined(__APPLE__)
    if (left == NULL || right == NULL) {
        return -EINVAL;
    }
    struct stat left_metadata;
    struct stat right_metadata;
    if (stat(left, &left_metadata) != 0) {
        return -(errno == 0 ? EIO : errno);
    }
    if (stat(right, &right_metadata) != 0) {
        if (errno == ENOENT) {
            return 0;
        }
        return -(errno == 0 ? EIO : errno);
    }
    return left_metadata.st_dev == right_metadata.st_dev &&
           left_metadata.st_ino == right_metadata.st_ino;
#else
    (void)left;
    (void)right;
    return -1;
#endif
}

#if defined(__unix__) || defined(__APPLE__)
static int mochi_remove_stage_tree(const char *path) {
    struct stat metadata;
    if (lstat(path, &metadata) != 0) {
        return errno == ENOENT ? 0 : (errno == 0 ? -1 : errno);
    }
    if (!S_ISDIR(metadata.st_mode)) {
        if (unlink(path) == 0 || errno == ENOENT) {
            return 0;
        }
        return errno == 0 ? -1 : errno;
    }

    /* Snapshot directories are frozen before compilation. Restore only the
       owner permissions needed to enumerate and unlink their contents. */
    if (chmod(path, 0700) != 0) {
        return errno == 0 ? -1 : errno;
    }
    DIR *directory = opendir(path);
    if (directory == NULL) {
        return errno == 0 ? -1 : errno;
    }
    int result = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0 && result == 0) {
                result = errno;
            }
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        size_t path_length = strlen(path);
        size_t name_length = strlen(entry->d_name);
        if (path_length > SIZE_MAX - name_length - 2) {
            result = EOVERFLOW;
            break;
        }
        size_t child_length = path_length + name_length + 2;
        char *child = (char *)malloc(child_length);
        if (child == NULL) {
            result = ENOMEM;
            break;
        }
        int written = snprintf(
            child, child_length, "%s/%s", path, entry->d_name
        );
        if (written < 0 || (size_t)written >= child_length) {
            free(child);
            result = EOVERFLOW;
            break;
        }
        int child_result = mochi_remove_stage_tree(child);
        free(child);
        if (child_result != 0) {
            result = child_result;
            break;
        }
    }
    if (closedir(directory) != 0 && result == 0) {
        result = errno == 0 ? -1 : errno;
    }
    if (result != 0) {
        return result;
    }
    if (rmdir(path) == 0 || errno == ENOENT) {
        return 0;
    }
    return errno == 0 ? -1 : errno;
}
#endif

int mochi_remove_plugin_stage(const char *path) {
#if defined(__unix__) || defined(__APPLE__)
    if (path == NULL || path[0] == '\0') {
        return EINVAL;
    }
    const char *basename = strrchr(path, '/');
    basename = basename == NULL ? path : basename + 1;
    static const char prefix[] = ".mochi-plugin-stage-";
    if (strncmp(basename, prefix, sizeof(prefix) - 1) != 0 ||
        basename[sizeof(prefix) - 1] == '\0') {
        return EINVAL;
    }
    return mochi_remove_stage_tree(path);
#else
    (void)path;
    return -1;
#endif
}

int mochi_secure_random(void *buffer, size_t length) {
#if defined(__unix__) || defined(__APPLE__)
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        return errno == 0 ? -1 : errno;
    }
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = read(fd, (unsigned char *)buffer + offset, length - offset);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            int error = errno == 0 ? -1 : errno;
            close(fd);
            return error;
        }
        offset += (size_t)count;
    }
    close(fd);
    return 0;
#else
    (void)buffer;
    (void)length;
    return -1;
#endif
}

int mochi_open_browser(const char *url) {
#if defined(__unix__) || defined(__APPLE__)
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
#if defined(__APPLE__)
        execlp("open", "open", url, (char *)NULL);
#else
        execlp("xdg-open", "xdg-open", url, (char *)NULL);
#endif
        _exit(127);
    }
    return 0;
#else
    (void)url;
    return -1;
#endif
}

int mochi_oauth_callback_bind(int preferred_port, int *bound_port) {
#if defined(__unix__) || defined(__APPLE__)
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        return -1;
    }
    int reuse = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons((uint16_t)preferred_port);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0) {
        address.sin_port = 0;
        if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0) {
            close(server);
            return -1;
        }
    }
    if (listen(server, 1) != 0) {
        close(server);
        return -1;
    }
    socklen_t size = sizeof(address);
    if (getsockname(server, (struct sockaddr *)&address, &size) != 0) {
        close(server);
        return -1;
    }
    *bound_port = ntohs(address.sin_port);
    return server;
#else
    (void)preferred_port;
    (void)bound_port;
    return -1;
#endif
}

int mochi_oauth_callback_wait(int server, char *output, size_t capacity, int timeout_seconds) {
#if defined(__unix__) || defined(__APPLE__)
    if (capacity == 0) {
        close(server);
        return -1;
    }
    fd_set reads;
    FD_ZERO(&reads);
    FD_SET(server, &reads);
    FD_SET(STDIN_FILENO, &reads);
    int maximum = server > STDIN_FILENO ? server : STDIN_FILENO;
    struct timeval timeout = {.tv_sec = timeout_seconds, .tv_usec = 0};
    int ready;
    do {
        ready = select(maximum + 1, &reads, NULL, NULL, &timeout);
    } while (ready < 0 && errno == EINTR);
    if (ready <= 0) {
        close(server);
        return -1;
    }
    if (FD_ISSET(STDIN_FILENO, &reads)) {
        if (fgets(output, (int)capacity, stdin) == NULL) {
            close(server);
            return -1;
        }
        output[strcspn(output, "\r\n")] = '\0';
        close(server);
        return 1;
    }
    int client = accept(server, NULL, NULL);
    close(server);
    if (client < 0) {
        return -1;
    }
    char request[8192];
    ssize_t count = recv(client, request, sizeof(request) - 1, 0);
    if (count <= 0) {
        close(client);
        return -1;
    }
    request[count] = '\0';
    char *start = strchr(request, ' ');
    char *end = start == NULL ? NULL : strchr(start + 1, ' ');
    if (start == NULL || end == NULL) {
        close(client);
        return -1;
    }
    size_t length = (size_t)(end - start - 1);
    if (length >= capacity) {
        length = capacity - 1;
    }
    memcpy(output, start + 1, length);
    output[length] = '\0';
    const char *body = "Authorization received. You can close this window.";
    char response[512];
    int response_length = snprintf(
        response,
        sizeof(response),
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
        strlen(body),
        body
    );
    if (response_length > 0) {
        (void)send(client, response, (size_t)response_length, 0);
    }
    close(client);
    return 0;
#else
    (void)server;
    (void)output;
    (void)capacity;
    (void)timeout_seconds;
    return -1;
#endif
}

typedef struct mochi_cancellation_state {
    atomic_uint_least64_t references;
    atomic_bool cancelled;
    struct mochi_cancellation_state *parent;
} mochi_cancellation_state;

#if defined(__unix__) || defined(__APPLE__)
static _Atomic(mochi_cancellation_state *) mochi_active_cancellation = NULL;
static struct sigaction mochi_previous_sigint;
static bool mochi_sigint_installed = false;

static void mochi_handle_sigint(int signal_number) {
    (void)signal_number;
    mochi_cancellation_state *state = atomic_load_explicit(
        &mochi_active_cancellation, memory_order_acquire
    );
    if (state != NULL) {
        atomic_store_explicit(&state->cancelled, true, memory_order_release);
    }
}
#endif

static mochi_cancellation_state *mochi_cancellation_alloc(
    mochi_cancellation_state *parent
) {
    mochi_cancellation_state *state = malloc(sizeof(*state));
    if (state == NULL) {
        abort();
    }
    atomic_init(&state->references, 1);
    atomic_init(&state->cancelled, false);
    state->parent = parent;
    return state;
}

void *mochi_cancellation_new(void) {
    return mochi_cancellation_alloc(NULL);
}

void mochi_cancellation_retain(void *handle) {
    mochi_cancellation_state *state = handle;
    atomic_fetch_add_explicit(&state->references, 1, memory_order_relaxed);
}

void mochi_cancellation_release(void *handle) {
    mochi_cancellation_state *state = handle;
    if (atomic_fetch_sub_explicit(
            &state->references, 1, memory_order_acq_rel
        ) == 1) {
        mochi_cancellation_state *parent = state->parent;
        free(state);
        if (parent != NULL) {
            mochi_cancellation_release(parent);
        }
    }
}

void *mochi_cancellation_child(void *handle) {
    mochi_cancellation_state *parent = handle;
    mochi_cancellation_retain(parent);
    return mochi_cancellation_alloc(parent);
}

void mochi_cancellation_cancel(void *handle) {
    mochi_cancellation_state *state = handle;
    atomic_store_explicit(&state->cancelled, true, memory_order_release);
}

void mochi_cancellation_activate_sigint(void *handle) {
#if defined(__unix__) || defined(__APPLE__)
    mochi_cancellation_state *state = handle;
    mochi_cancellation_retain(state);
    mochi_cancellation_state *previous = atomic_exchange_explicit(
        &mochi_active_cancellation, state, memory_order_acq_rel
    );
    if (previous != NULL) {
        mochi_cancellation_release(previous);
    }
    if (!mochi_sigint_installed) {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = mochi_handle_sigint;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGINT, &action, &mochi_previous_sigint) == 0) {
            mochi_sigint_installed = true;
        }
    }
#else
    (void)handle;
#endif
}

void mochi_cancellation_deactivate_sigint(void) {
#if defined(__unix__) || defined(__APPLE__)
    mochi_cancellation_state *state = atomic_exchange_explicit(
        &mochi_active_cancellation, NULL, memory_order_acq_rel
    );
    if (state != NULL) {
        mochi_cancellation_release(state);
    }
    if (mochi_sigint_installed) {
        (void)sigaction(SIGINT, &mochi_previous_sigint, NULL);
        mochi_sigint_installed = false;
    }
#endif
}

int mochi_cancellation_is_cancelled(void *handle) {
    mochi_cancellation_state *state = handle;
    while (state != NULL) {
        if (atomic_load_explicit(&state->cancelled, memory_order_acquire)) {
            return 1;
        }
        state = state->parent;
    }
    return 0;
}

#if defined(__unix__) || defined(__APPLE__)
static struct termios mochi_terminal_original;
static bool mochi_terminal_raw = false;
static bool mochi_terminal_input_modes = false;

void mochi_terminal_set_input_modes(int enabled) {
    static const char enable[] = "\x1b[?2004h\x1b[?1000h\x1b[?1002h\x1b[?1006h";
    static const char disable[] = "\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?2004l";
    const char *sequence = enabled ? enable : disable;
    size_t length = enabled ? sizeof(enable) - 1 : sizeof(disable) - 1;
    ssize_t ignored = write(STDOUT_FILENO, sequence, length);
    (void)ignored;
    mochi_terminal_input_modes = enabled != 0;
}

void mochi_terminal_disable_raw(void) {
    if (mochi_terminal_input_modes) {
        mochi_terminal_set_input_modes(0);
    }
    if (mochi_terminal_raw) {
        (void)tcsetattr(STDIN_FILENO, TCSAFLUSH, &mochi_terminal_original);
        mochi_terminal_raw = false;
    }
}

int mochi_terminal_columns(void) {
    struct winsize size;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0 || size.ws_col == 0) {
        return 0;
    }
    return (int)size.ws_col;
}

static int mochi_write_all(int fd, const char *data, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(fd, data + offset, length - offset);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return errno == 0 ? -1 : errno;
        }
        offset += (size_t)count;
    }
    return 0;
}

int mochi_terminal_write(const char *data, size_t length) {
    return mochi_write_all(STDOUT_FILENO, data, length);
}

int mochi_osc52_clipboard_write(const char *data, size_t length) {
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    static const char prefix[] = "\x1b]52;c;";
    static const char suffix[] = "\x07";
    if (mochi_write_all(STDOUT_FILENO, prefix, sizeof(prefix) - 1) != 0) {
        return -1;
    }
    size_t offset = 0;
    while (offset < length) {
        unsigned int value = (unsigned char)data[offset] << 16;
        size_t remaining = length - offset;
        if (remaining > 1) {
            value |= (unsigned char)data[offset + 1] << 8;
        }
        if (remaining > 2) {
            value |= (unsigned char)data[offset + 2];
        }
        char encoded[4] = {
            alphabet[(value >> 18) & 63],
            alphabet[(value >> 12) & 63],
            remaining > 1 ? alphabet[(value >> 6) & 63] : '=',
            remaining > 2 ? alphabet[value & 63] : '=',
        };
        if (mochi_write_all(STDOUT_FILENO, encoded, sizeof(encoded)) != 0) {
            return -1;
        }
        offset += remaining >= 3 ? 3 : remaining;
    }
    return mochi_write_all(STDOUT_FILENO, suffix, sizeof(suffix) - 1);
}

int mochi_native_clipboard_write(const char *data, size_t length) {
#if defined(__APPLE__)
    int descriptors[2];
    if (pipe(descriptors) != 0) {
        return errno == 0 ? -1 : errno;
    }
    pid_t pid = fork();
    if (pid < 0) {
        int error = errno == 0 ? -1 : errno;
        close(descriptors[0]);
        close(descriptors[1]);
        return error;
    }
    if (pid == 0) {
        (void)dup2(descriptors[0], STDIN_FILENO);
        close(descriptors[0]);
        close(descriptors[1]);
        execlp("pbcopy", "pbcopy", (char *)NULL);
        _exit(127);
    }
    close(descriptors[0]);
    int result = mochi_write_all(descriptors[1], data, length);
    close(descriptors[1]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    if (result != 0) {
        return result;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
#else
    (void)data;
    (void)length;
    return -1;
#endif
}

int mochi_terminal_read_byte(int timeout_milliseconds) {
    fd_set descriptors;
    FD_ZERO(&descriptors);
    FD_SET(STDIN_FILENO, &descriptors);
    struct timeval timeout;
    timeout.tv_sec = timeout_milliseconds / 1000;
    timeout.tv_usec = (timeout_milliseconds % 1000) * 1000;
    int ready = select(STDIN_FILENO + 1, &descriptors, NULL, NULL, &timeout);
    if (ready <= 0) {
        return -1;
    }
    unsigned char byte = 0;
    return read(STDIN_FILENO, &byte, 1) == 1 ? (int)byte : -1;
}

int mochi_change_directory(
    const char *path, char *resolved, size_t resolved_capacity
) {
    if (path == NULL || resolved == NULL || resolved_capacity == 0) {
        return EINVAL;
    }
    if (chdir(path) != 0) {
        return errno;
    }
    if (getcwd(resolved, resolved_capacity) == NULL) {
        return errno;
    }
    return 0;
}

int mochi_terminal_enable_raw(void) {
    if (!isatty(STDIN_FILENO)) {
        return 0;
    }
    if (mochi_terminal_raw) {
        return 1;
    }
    if (tcgetattr(STDIN_FILENO, &mochi_terminal_original) != 0) {
        return -1;
    }
    struct termios raw = mochi_terminal_original;
    raw.c_iflag &= (tcflag_t)~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= (tcflag_t)~OPOST;
    raw.c_cflag |= CS8;
    raw.c_lflag &= (tcflag_t)~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) {
        return -1;
    }
    mochi_terminal_raw = true;
    (void)atexit(mochi_terminal_disable_raw);
    return 1;
}

typedef struct mochi_cancel_after_args {
    mochi_cancellation_state *state;
    int milliseconds;
} mochi_cancel_after_args;

static void *mochi_cancel_after_run(void *raw) {
    mochi_cancel_after_args *args = raw;
    struct timespec delay = {
        .tv_sec = args->milliseconds / 1000,
        .tv_nsec = (long)(args->milliseconds % 1000) * 1000000L,
    };
    nanosleep(&delay, NULL);
    mochi_cancellation_cancel(args->state);
    mochi_cancellation_release(args->state);
    free(args);
    return NULL;
}

int mochi_cancellation_cancel_after(void *handle, int milliseconds) {
    mochi_cancel_after_args *args = malloc(sizeof(*args));
    if (args == NULL) {
        return -1;
    }
    args->state = handle;
    args->milliseconds = milliseconds;
    mochi_cancellation_retain(handle);
    pthread_t thread;
    if (pthread_create(&thread, NULL, mochi_cancel_after_run, args) != 0) {
        mochi_cancellation_release(handle);
        free(args);
        return -1;
    }
    pthread_detach(thread);
    return 0;
}

static int mochi_send_all(int fd, const char *data, size_t size) {
    while (size > 0) {
        ssize_t sent = send(fd, data, size, 0);
        if (sent <= 0) {
            return -1;
        }
        data += sent;
        size -= (size_t)sent;
    }
    return 0;
}

static void *mochi_http_fixture_run(void *raw) {
    int server = *(int *)raw;
    free(raw);
    int client = accept(server, NULL, NULL);
    if (client >= 0) {
        char request[1024];
        (void)recv(client, request, sizeof(request), 0);
        const char *headers =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/plain\r\n"
            "Content-Length: 11\r\n"
            "Connection: close\r\n\r\n";
        (void)mochi_send_all(client, headers, strlen(headers));
        (void)mochi_send_all(client, "first", 5);
        struct timespec delay = {.tv_sec = 2, .tv_nsec = 0};
        nanosleep(&delay, NULL);
        (void)mochi_send_all(client, "second", 6);
        close(client);
    }
    close(server);
    return NULL;
}

int mochi_http_fixture_start(void) {
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        return -1;
    }
    int reuse = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(server, 1) != 0) {
        close(server);
        return -1;
    }
    socklen_t size = sizeof(address);
    if (getsockname(server, (struct sockaddr *)&address, &size) != 0) {
        close(server);
        return -1;
    }
    int *argument = malloc(sizeof(*argument));
    if (argument == NULL) {
        close(server);
        return -1;
    }
    *argument = server;
    pthread_t thread;
    if (pthread_create(&thread, NULL, mochi_http_fixture_run, argument) != 0) {
        free(argument);
        close(server);
        return -1;
    }
    pthread_detach(thread);
    return ntohs(address.sin_port);
}
#else
int mochi_terminal_read_byte(int timeout_milliseconds) {
    (void)timeout_milliseconds;
    return -1;
}

int mochi_terminal_columns(void) {
    return 0;
}

int mochi_terminal_write(const char *data, size_t length) {
    (void)data;
    (void)length;
    return -1;
}

int mochi_native_clipboard_write(const char *data, size_t length) {
    (void)data;
    (void)length;
    return -1;
}

int mochi_osc52_clipboard_write(const char *data, size_t length) {
    (void)data;
    (void)length;
    return -1;
}

int mochi_change_directory(
    const char *path, char *resolved, size_t resolved_capacity
) {
    (void)path;
    (void)resolved;
    (void)resolved_capacity;
    return -1;
}

int mochi_terminal_enable_raw(void) {
    return 0;
}

void mochi_terminal_set_input_modes(int enabled) {
    (void)enabled;
}

void mochi_terminal_disable_raw(void) {
}

int mochi_cancellation_cancel_after(void *handle, int milliseconds) {
    (void)handle;
    (void)milliseconds;
    return -1;
}

int mochi_http_fixture_start(void) {
    return -1;
}
#endif
