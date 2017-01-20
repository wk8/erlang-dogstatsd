#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "erl_nif.h"

#define BUFFER_SIZE 4096
#define MAX_IP_SIZE 64

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_set_server_info_failed;
static ERL_NIF_TERM atom_must_set_server_info_first;
static ERL_NIF_TERM atom_send_failed;
static ERL_NIF_TERM atom_cannot_allocate_worker_space;

// each VM-level thread gets its own socket and buffer, that we keep in a linked
// list
typedef struct worker_space_t {
  int socket;
  ErlNifBinary* buffer;
  ErlNifTid thread_id;
  struct worker_space_t* next;
} worker_space_t;

static worker_space_t* pool = NULL;
int current_pool_size = 0;

// adding to the pool and setting the server info need to be synchronized
ErlNifMutex* mutex = NULL;

typedef enum { NO_SERVER_INFO, SERVER_INFO_SET, SET_SERVER_INFO_FAILED } server_info_state;
static server_info_state server_info_status = NO_SERVER_INFO;

static char server_ip[MAX_IP_SIZE];
static int server_port;
static struct sockaddr_in edogstatsd_server;
static int sockaddr_in_size = sizeof(struct sockaddr_in);

// expects the server's IP (as a string) as first argument, and the port as
// second argument (as an int)
static ERL_NIF_TERM edogstatsd_udp_set_server_info(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  enif_mutex_lock(mutex);

  // process arguments
  if (enif_get_string(env, argv[0], server_ip, MAX_IP_SIZE, ERL_NIF_LATIN1) <= 0
      || !enif_get_int(env, argv[1], &server_port)) {
    return enif_make_badarg(env);
  }
  // inet_aton doesn't like "localhost"...
  if (!strcmp(server_ip, "localhost")) {
    memcpy(server_ip, "127.0.0.1", 10);
  }

  ERL_NIF_TERM result;

  // populate the sockaddr_in
  memset(&edogstatsd_server, 0, sockaddr_in_size);
  edogstatsd_server.sin_family = AF_INET;
  edogstatsd_server.sin_port = htons(server_port);
  if (inet_aton(server_ip, &edogstatsd_server.sin_addr)) {
    result = atom_ok;
    server_info_status = SERVER_INFO_SET;
  } else {
    result = enif_make_tuple2(env, atom_error, enif_make_atom(env, "inet_aton_failed"));
    server_info_status = SET_SERVER_INFO_FAILED;
  }

  enif_mutex_unlock(mutex);

  return result;
}

void free_worker_space(worker_space_t* worker_space)
{
  if (worker_space) {
    if (worker_space->buffer) {
      enif_release_binary(worker_space->buffer);
      free(worker_space->buffer);
    }

    if (worker_space->socket >= 0) {
      close(worker_space->socket);
    }

    free(worker_space);
  }
}

worker_space_t* alloc_worker_space(ErlNifTid self)
{
  worker_space_t* worker_space = (worker_space_t*) malloc(sizeof(worker_space_t));
  if (!worker_space) {
    return NULL;
  }

  worker_space->socket = -1;
  worker_space->buffer = NULL;
  worker_space->thread_id = self;
  worker_space->next = NULL;

  // allocate the buffer
  worker_space->buffer = (ErlNifBinary*) malloc(sizeof(ErlNifBinary));
  if (!worker_space->buffer) {
    goto cleanup_failed_alloc_worker_space;
  }
  if (!enif_alloc_binary(BUFFER_SIZE, worker_space->buffer)) {
    free(worker_space->buffer);
    worker_space->buffer = NULL;
    goto cleanup_failed_alloc_worker_space;
  }

  // open the socket
  worker_space->socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (worker_space->socket == -1) {
    goto cleanup_failed_alloc_worker_space;
  }

  return worker_space;

cleanup_failed_alloc_worker_space:
  free(worker_space);
  return NULL;
}

worker_space_t* create_worker_space_for_current_thread(ErlNifTid self)
{
  // let's create it
  worker_space_t* worker_space = alloc_worker_space(self);
  if (!worker_space) {
    return NULL;
  }

  // now let's add it to the pool
  enif_mutex_lock(mutex);

  worker_space->next = pool;
  pool = worker_space;
  current_pool_size++;

  enif_mutex_unlock(mutex);

  return worker_space;
}

worker_space_t* get_current_thread_worker_space()
{
  worker_space_t* current = pool;
  ErlNifTid self = enif_thread_self();

  while (current) {
    if (enif_equal_tids(current->thread_id, self)) {
      return current;
    }
    current = current->next;
  }

  // seems the current thread doesn't have its own worker space yet, let's
  // create one!
  return create_worker_space_for_current_thread(self);
}

// the only argument should be an IO data
static ERL_NIF_TERM do_edogstatsd_udp_send_line(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  worker_space_t* worker_space;
  ErlNifBinary* buffer;
  int sent_count;

  worker_space = get_current_thread_worker_space();
  if (!worker_space) {
    return enif_make_tuple2(env, atom_error, atom_cannot_allocate_worker_space);
  }
  buffer = worker_space->buffer;

  if (!enif_inspect_iolist_as_binary(env, argv[0], buffer)) {
    return enif_make_badarg(env);
  }

  sent_count = sendto(worker_space->socket, buffer->data, buffer->size, 0,
                      (struct sockaddr*) &edogstatsd_server, sockaddr_in_size);
  if (sent_count != buffer->size) {
    ERL_NIF_TERM error_tuple = enif_make_tuple3(env, atom_send_failed, sent_count, buffer->size);
    return enif_make_tuple2(env, atom_error, error_tuple);
  }

  return atom_ok;
}

static ERL_NIF_TERM edogstatsd_udp_send_line(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  switch(server_info_status) {
    case SERVER_INFO_SET:
      return do_edogstatsd_udp_send_line(env, argc, argv);
    case SET_SERVER_INFO_FAILED:
      return enif_make_tuple2(env, atom_error, atom_set_server_info_failed);
    case NO_SERVER_INFO:
    default:
      return enif_make_tuple2(env, atom_error, atom_must_set_server_info_first);
  }
}

static ERL_NIF_TERM edogstatsd_udp_current_pool_size(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  return enif_make_int(env, current_pool_size);
}

static int edogstatsd_udp_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
  atom_ok                           = enif_make_atom(env, "ok");
  atom_error                        = enif_make_atom(env, "error");
  atom_set_server_info_failed       = enif_make_atom(env, "set_server_info_failed");
  atom_must_set_server_info_first   = enif_make_atom(env, "must_set_server_info_first");
  atom_send_failed                  = enif_make_atom(env, "send_failed");
  atom_cannot_allocate_worker_space = enif_make_atom(env, "cannot_allocate_worker_space");

  // create the mutex
  mutex = enif_mutex_create("edogstatsd_udp_mutex");

  return mutex ? 0 : 1;
}

static int edogstatsd_udp_upgrade(ErlNifEnv* env, void** priv_data, void** old_priv_data, ERL_NIF_TERM load_info)
{
  // nothing to do
  return 0;
}

static void edogstatsd_udp_unload(ErlNifEnv* env, void* priv_data)
{
  enif_mutex_lock(mutex);

  // empty the pool
  worker_space_t* current = pool, *next;
  while (current) {
    next = current->next;
    free_worker_space(current);
    current = next;
  }

  // destroy the mutex
  enif_mutex_unlock(mutex);
  enif_mutex_destroy(mutex);
}

static ErlNifFunc edogstatsd_udp_nif_funcs[] = {
  {"set_server_info",   2, edogstatsd_udp_set_server_info},
  {"send_line",         1, edogstatsd_udp_send_line},
  {"current_pool_size", 0, edogstatsd_udp_current_pool_size}
};

ERL_NIF_INIT(edogstatsd_udp, edogstatsd_udp_nif_funcs, edogstatsd_udp_load,
             NULL, edogstatsd_udp_upgrade, edogstatsd_udp_unload)
