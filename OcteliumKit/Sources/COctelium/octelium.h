#ifndef OCTELIUM_H
#define OCTELIUM_H

#include <stddef.h>
#include <stdint.h>

typedef void (*octelium_event_fn)(void *ctx, const uint8_t *data, size_t data_len);

typedef void (*octelium_request_fn)(void *ctx, uint64_t request_id,
    const uint8_t *data, size_t data_len);

typedef struct {
    void *ctx;
    octelium_event_fn on_event;
    octelium_request_fn on_request;
} octelium_callbacks_t;

uint32_t octelium_abi_version(void);

int32_t octelium_client_new(const uint8_t *config, size_t config_len,
    const octelium_callbacks_t *callbacks, uint64_t *client,
    uint8_t **out, size_t *out_len);

int32_t octelium_client_call(uint64_t client, const char *method,
    const uint8_t *req, size_t req_len,
    uint8_t **out, size_t *out_len);

int32_t octelium_client_complete_request(uint64_t client, uint64_t request_id,
    const uint8_t *resp, size_t resp_len);

void octelium_client_free(uint64_t client);

void octelium_free(void *ptr);

#endif
