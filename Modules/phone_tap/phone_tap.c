#include <errno.h>
#include <fcntl.h>
#include <re.h>
#include <rem.h>
#include <baresip.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define PHONE_TAP_SOCKET_FORMAT "/tmp/phone-audio-%u.sock"
#define PHONE_INJECT_SOCKET_FORMAT "/tmp/phone-audio-inject-%u.sock"
#define PHONE_TAP_MAX_PAYLOAD (60U * 1024U)
#define PHONE_INJECT_BUFFER_SIZE (192U * 1024U)

enum phone_direction {
    PHONE_DIRECTION_TX = 1,
    PHONE_DIRECTION_RX = 2
};

struct phone_header {
    uint8_t magic[4];
    uint8_t version;
    uint8_t direction;
    uint8_t format;
    uint8_t channels;
    uint32_t sample_rate_le;
    uint32_t payload_size_le;
} __attribute__((packed));

struct phone_enc {
    struct aufilt_enc_st af;
};

struct phone_dec {
    struct aufilt_dec_st af;
};

static int tap_socket = -1;
static struct sockaddr_un tap_address;
static int inject_socket = -1;
static char inject_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static uint8_t inject_buffer[PHONE_INJECT_BUFFER_SIZE];
static size_t inject_head;
static size_t inject_count;

static uint32_t little_endian_u32(uint32_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return value;
#else
    return __builtin_bswap32(value);
#endif
}

static uint8_t wire_format(enum aufmt format)
{
    switch (format) {
    case AUFMT_S16LE: return 1;
    case AUFMT_S32LE: return 2;
    case AUFMT_FLOAT: return 3;
    default: return 0;
    }
}

static void inject_append(const uint8_t *samples, size_t size)
{
    size_t available;
    size_t first;
    size_t tail;

    if (!samples || !size)
        return;
    if (size > PHONE_INJECT_BUFFER_SIZE) {
        samples += size - PHONE_INJECT_BUFFER_SIZE;
        size = PHONE_INJECT_BUFFER_SIZE;
    }
    available = PHONE_INJECT_BUFFER_SIZE - inject_count;
    if (size > available) {
        size_t discard = size - available;
        inject_head = (inject_head + discard) % PHONE_INJECT_BUFFER_SIZE;
        inject_count -= discard;
    }
    tail = (inject_head + inject_count) % PHONE_INJECT_BUFFER_SIZE;
    first = PHONE_INJECT_BUFFER_SIZE - tail;
    if (first > size)
        first = size;
    memcpy(inject_buffer + tail, samples, first);
    memcpy(inject_buffer, samples + first, size - first);
    inject_count += size;
}

static size_t inject_read(uint8_t *samples, size_t size)
{
    size_t first;

    if (!samples || !size || !inject_count)
        return 0;
    if (size > inject_count)
        size = inject_count;
    first = PHONE_INJECT_BUFFER_SIZE - inject_head;
    if (first > size)
        first = size;
    memcpy(samples, inject_buffer + inject_head, first);
    memcpy(samples + first, inject_buffer, size - first);
    inject_head = (inject_head + size) % PHONE_INJECT_BUFFER_SIZE;
    inject_count -= size;
    return size;
}

static void drain_injected_audio(const struct auframe *frame)
{
    uint8_t packet[sizeof(struct phone_header) + PHONE_TAP_MAX_PAYLOAD];
    ssize_t received;

    if (inject_socket < 0 || !frame)
        return;
    while ((received = recv(inject_socket, packet, sizeof(packet), MSG_DONTWAIT)) > 0) {
        const struct phone_header *header;
        uint32_t sample_rate;
        uint32_t payload_size;

        if ((size_t)received < sizeof(*header))
            continue;
        header = (const struct phone_header *)packet;
        memcpy(&sample_rate, &header->sample_rate_le, sizeof(sample_rate));
        memcpy(&payload_size, &header->payload_size_le, sizeof(payload_size));
        sample_rate = little_endian_u32(sample_rate);
        payload_size = little_endian_u32(payload_size);
        if (memcmp(header->magic, "PTAI", 4) != 0 ||
            header->version != 1 ||
            header->direction != PHONE_DIRECTION_TX ||
            header->format != wire_format(frame->fmt) ||
            header->channels != frame->ch ||
            sample_rate != frame->srate ||
            !payload_size ||
            payload_size > PHONE_TAP_MAX_PAYLOAD ||
            (size_t)received != sizeof(*header) + payload_size)
            continue;
        inject_append(packet + sizeof(*header), payload_size);
    }
}

static void inject_frame(struct auframe *frame)
{
    size_t payload_size;

    if (!frame || !frame->sampv)
        return;
    drain_injected_audio(frame);
    if (!inject_count)
        return;
    payload_size = auframe_size(frame);
    if (!payload_size)
        return;
    memset(frame->sampv, 0, payload_size);
    (void)inject_read(frame->sampv, payload_size);
}

static void state_destructor(void *arg)
{
    struct aufilt_enc_st *state = arg;
    list_unlink(&state->le);
}

static int encode_update(struct aufilt_enc_st **statep, void **context,
                         const struct aufilt *filter, struct aufilt_prm *parameters,
                         const struct audio *audio)
{
    struct phone_enc *state;
    (void)context;
    (void)filter;
    (void)parameters;
    (void)audio;

    if (!statep)
        return EINVAL;
    state = mem_zalloc(sizeof(*state), state_destructor);
    if (!state)
        return ENOMEM;
    *statep = (struct aufilt_enc_st *)state;
    return 0;
}

static int decode_update(struct aufilt_dec_st **statep, void **context,
                         const struct aufilt *filter, struct aufilt_prm *parameters,
                         const struct audio *audio)
{
    struct phone_dec *state;
    (void)context;
    (void)filter;
    (void)parameters;
    (void)audio;

    if (!statep)
        return EINVAL;
    state = mem_zalloc(sizeof(*state), state_destructor);
    if (!state)
        return ENOMEM;
    *statep = (struct aufilt_dec_st *)state;
    return 0;
}

static void send_frame(const struct auframe *frame, uint8_t direction)
{
    struct phone_header header;
    struct iovec vectors[2];
    struct msghdr message;
    size_t payload_size;
    uint8_t format;

    if (tap_socket < 0 || !frame || !frame->sampv)
        return;

    format = wire_format(frame->fmt);
    payload_size = auframe_size(frame);
    if (!format || !payload_size || payload_size > PHONE_TAP_MAX_PAYLOAD)
        return;

    memset(&header, 0, sizeof(header));
    memcpy(header.magic, "PTAP", 4);
    header.version = 1;
    header.direction = direction;
    header.format = format;
    header.channels = frame->ch;
    header.sample_rate_le = little_endian_u32(frame->srate);
    header.payload_size_le = little_endian_u32((uint32_t)payload_size);

    vectors[0].iov_base = &header;
    vectors[0].iov_len = sizeof(header);
    vectors[1].iov_base = frame->sampv;
    vectors[1].iov_len = payload_size;

    memset(&message, 0, sizeof(message));
    message.msg_name = &tap_address;
    message.msg_namelen = sizeof(tap_address);
    message.msg_iov = vectors;
    message.msg_iovlen = 2;

    (void)sendmsg(tap_socket, &message, MSG_DONTWAIT);
}

static int encode(struct aufilt_enc_st *state, struct auframe *frame)
{
    (void)state;
    send_frame(frame, PHONE_DIRECTION_TX);
    inject_frame(frame);
    return 0;
}

static int decode(struct aufilt_dec_st *state, struct auframe *frame)
{
    (void)state;
    send_frame(frame, PHONE_DIRECTION_RX);
    return 0;
}

static struct aufilt phone_tap = {
    .name = "phone_tap",
    .encupdh = encode_update,
    .ench = encode,
    .decupdh = decode_update,
    .dech = decode
};

static int module_init(void)
{
    struct sockaddr_un inject_address;

    tap_socket = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (tap_socket < 0)
        return errno;

    (void)fcntl(tap_socket, F_SETFL, O_NONBLOCK);
    memset(&tap_address, 0, sizeof(tap_address));
    tap_address.sun_family = AF_UNIX;
    /* Per-user socket path, matching AudioTapServer.socketPath on the app side. */
    (void)snprintf(tap_address.sun_path, sizeof(tap_address.sun_path),
                   PHONE_TAP_SOCKET_FORMAT, (unsigned)getuid());

    inject_socket = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (inject_socket < 0) {
        int error = errno;
        close(tap_socket);
        tap_socket = -1;
        return error;
    }
    (void)fcntl(inject_socket, F_SETFL, O_NONBLOCK);
    memset(&inject_address, 0, sizeof(inject_address));
    inject_address.sun_family = AF_UNIX;
    (void)snprintf(inject_path, sizeof(inject_path),
                   PHONE_INJECT_SOCKET_FORMAT, (unsigned)getuid());
    (void)snprintf(inject_address.sun_path, sizeof(inject_address.sun_path),
                   "%s", inject_path);
    (void)unlink(inject_path);
    if (bind(inject_socket, (const struct sockaddr *)&inject_address,
             sizeof(inject_address)) < 0) {
        int error = errno;
        close(inject_socket);
        close(tap_socket);
        inject_socket = -1;
        tap_socket = -1;
        return error;
    }
    (void)chmod(inject_path, S_IRUSR | S_IWUSR);

    aufilt_register(baresip_aufiltl(), &phone_tap);
    info("phone_tap: local RX/TX audio bridge ready\n");
    return 0;
}

static int module_close(void)
{
    aufilt_unregister(&phone_tap);
    if (tap_socket >= 0) {
        close(tap_socket);
        tap_socket = -1;
    }
    if (inject_socket >= 0) {
        close(inject_socket);
        inject_socket = -1;
    }
    if (inject_path[0]) {
        (void)unlink(inject_path);
        inject_path[0] = '\0';
    }
    inject_head = 0;
    inject_count = 0;
    return 0;
}

EXPORT_SYM const struct mod_export DECL_EXPORTS(phone_tap) = {
    "phone_tap",
    "filter",
    module_init,
    module_close
};
