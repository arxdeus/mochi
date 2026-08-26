#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#if defined(__unix__) || defined(__APPLE__)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#endif

typedef struct mochi_cancellation_state {
    atomic_uint_least64_t references;
    atomic_bool cancelled;
    struct mochi_cancellation_state *parent;
} mochi_cancellation_state;

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

void mochi_terminal_disable_raw(void) {
    if (mochi_terminal_raw) {
        (void)tcsetattr(STDIN_FILENO, TCSAFLUSH, &mochi_terminal_original);
        mochi_terminal_raw = false;
    }
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
int mochi_terminal_enable_raw(void) {
    return 0;
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
