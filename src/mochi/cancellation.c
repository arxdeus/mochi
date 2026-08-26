#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>

#if defined(__unix__) || defined(__APPLE__)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#endif

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
    (void)write(STDOUT_FILENO, sequence, length);
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
