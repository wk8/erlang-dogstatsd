#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "erl_nif.h"

#define BUFFER_SIZE 4096
#define MAX_IP_SIZE 64
#define MAX_IDLE_POOL_SIZE 10

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_set_server_info_failed;
static ERL_NIF_TERM atom_must_set_server_info_first;
static ERL_NIF_TERM atom_not_an_io_list;
static ERL_NIF_TERM atom_send_failed;
static ERL_NIF_TERM atom_cannot_allocate_worker_space;

// we have a pool of socket and buffers that all processes share
typedef struct worker_space_t {
  int socket;
  ErlNifBinary* buffer;
  int version;
  // that's only ever non-NULL when sitting idle in the queue
  struct worker_space_t* next;
} worker_space_t;

static worker_space_t* pool = NULL;
static int current_pool_size = 0;
static int allocated_worker_spaces_count = 0;
static int destroyed_worker_spaces_count = 0;

// checking a socket and a buffer in and out of the pool needs to be
// synchronized
ErlNifRWLock* pool_lock = NULL;

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
  enif_rwlock_rwlock(pool_lock);

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

  enif_rwlock_rwunlock(pool_lock);

  return result;
}

// no need for a lock here since it's only ever called inside of
// check_in_worker_space below, that already locks
void free_worker_space(worker_space_t* worker_space)
{
  if (worker_space) {
    if (worker_space->buffer) {
      enif_release_binary(worker_space->buffer);
    }

    if (worker_space->socket >= 0) {
      close(worker_space->socket);
    }

    free(worker_space);
    destroyed_worker_spaces_count++;
  }
}

// same idea, no need for a lock here since it's only ever called inside of
// check_out_worker_space below, that already locks
worker_space_t* alloc_worker_space() {
  worker_space_t* worker_space = (worker_space_t*) calloc(1, sizeof(worker_space_t)); // TODO wkpo calloc header needed?

  if (!worker_space) {
    return NULL;
  }

  worker_space->socket = -1;
  worker_space->buffer = NULL;
  worker_space->next = NULL;

  // open the socket
  worker_space->socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (worker_space->socket == -1) {
    goto cleanup_failed_alloc_worker_space;
  }

  // allocate the buffer
  if (!enif_alloc_binary(BUFFER_SIZE, worker_space->buffer)) {
    goto cleanup_failed_alloc_worker_space;
  }

  allocated_worker_spaces_count++;
  return worker_space;

cleanup_failed_alloc_worker_space:
  free(worker_space);
  return NULL;
}

// checks out a worker space out of the pool
worker_space_t* check_out_worker_space()
{
  worker_space_t* worker_space;

  enif_rwlock_rwlock(pool_lock);

  // try to find one sitting idle in the pool
  if (pool) {
    worker_space = pool;
    pool = worker_space->next;
    worker_space->next = NULL;
    current_pool_size--;
  } else {
    // we haven't found any current worker in the queue, need to create a new
    // one
    worker_space = alloc_worker_space();
  }

  enif_rwlock_rwunlock(pool_lock);

  return worker_space;
}

// checks a worker space back into the pool
void check_in_worker_space(worker_space_t* worker_space)
{
  if (!worker_space) {
    return;
  }

  enif_rwlock_rwlock(pool_lock);

  if (current_pool_size >= MAX_IDLE_POOL_SIZE) {
    // we already have enough worker spaces sitting in the pool, fds are not
    // free, just get rid of this one
    free_worker_space(worker_space);
  } else {
    // just put it in the pool to be re-used later
    worker_space->next = pool;
    pool = worker_space;
    current_pool_size++;
  }

  enif_rwlock_rwunlock(pool_lock);
}

// the only argument should be a list of IO lists
static ERL_NIF_TERM do_edogstatsd_udp_send_lines(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  int sent_count;
  worker_space_t* worker_space = NULL;
  ErlNifBinary* buffer;
  ERL_NIF_TERM list = argv[0], current_io_list, tail, send_error,
               errors_list = enif_make_list(env, 0), result = 0;

  if (!enif_is_list(env, list)) {
    result = enif_make_badarg(env);
    goto cleanup_do_edogstatsd_udp_send_lines;
  }

  worker_space = check_out_worker_space();
  if (!worker_space) {
    result = enif_make_tuple2(env, atom_error, atom_cannot_allocate_worker_space);
    goto cleanup_do_edogstatsd_udp_send_lines;
  }
  buffer = worker_space->buffer;

  while(enif_get_list_cell(env, list, &current_io_list, &tail)) {
    list = tail;

    if (!enif_inspect_iolist_as_binary(env, current_io_list, buffer)) {
      send_error = enif_make_tuple2(env, atom_not_an_io_list, current_io_list);
      errors_list = enif_make_list_cell(env, send_error, list);
      continue;
    }

    sent_count = sendto(worker_space->socket, buffer->data, buffer->size, 0,
                        (struct sockaddr*) &edogstatsd_server, sockaddr_in_size);
    if (sent_count != buffer->size) {
      send_error = enif_make_tuple4(env, atom_error, atom_send_failed, sent_count, buffer->size);
      errors_list = enif_make_list_cell(env, send_error, list);
    }
  }

cleanup_do_edogstatsd_udp_send_lines:
  check_in_worker_space(worker_space);

  if (!enif_has_pending_exception(env, NULL) && !result) {
    if (enif_is_empty_list(env, errors_list)) {
      result = atom_ok;
    } else {
      // there were errors
      result = enif_make_tuple2(env, atom_error, errors_list);
    }
  }

  return result;
}

static ERL_NIF_TERM edogstatsd_udp_send_lines(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  switch(server_info_status) {
    case SERVER_INFO_SET:
      return do_edogstatsd_udp_send_lines(env, argc, argv);
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

static ERL_NIF_TERM edogstatsd_udp_allocated_worker_spaces_count(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  return enif_make_int(env, allocated_worker_spaces_count);
}

static ERL_NIF_TERM edogstatsd_udp_destroyed_worker_spaces_count(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
  return enif_make_int(env, destroyed_worker_spaces_count);
}

static int edogstatsd_udp_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
  atom_ok                           = enif_make_atom(env, "ok");
  atom_error                        = enif_make_atom(env, "error");
  atom_set_server_info_failed       = enif_make_atom(env, "set_server_info_failed");
  atom_must_set_server_info_first   = enif_make_atom(env, "must_set_server_info_first");
  atom_not_an_io_list               = enif_make_atom(env, "not_an_io_list");
  atom_send_failed                  = enif_make_atom(env, "send_failed");
  atom_cannot_allocate_worker_space = enif_make_atom(env, "cannot_allocate_worker_space");

  // init the lock
  pool_lock = enif_rwlock_create("edogstatsd_udp_pool_lock");

  return pool_lock ? 0 : 1;
}

static int edogstatsd_udp_upgrade(ErlNifEnv* env, void** priv_data, void** old_priv_data, ERL_NIF_TERM load_info)
{
  // nothing to do
  return 0;
}

static void edogstatsd_udp_unload(ErlNifEnv* env, void* priv_data)
{
  enif_rwlock_rwlock(pool_lock);

  // empty the pool
  worker_space_t* current = pool, *next;
  while (current) {
    next = current->next;
    free_worker_space(current);
    current = next;
  }

  // destroy the lock
  enif_rwlock_rwunlock(pool_lock);
  enif_rwlock_destroy(pool_lock);
}

static ErlNifFunc edogstatsd_udp_nif_funcs[] = {
  {"set_server_info",               2, edogstatsd_udp_set_server_info},
  {"send_lines",                    1, edogstatsd_udp_send_lines},
  {"current_pool_size",             0, edogstatsd_udp_current_pool_size},
  {"allocated_worker_spaces_count", 0, edogstatsd_udp_allocated_worker_spaces_count},
  {"destroyed_worker_spaces_count", 0, edogstatsd_udp_destroyed_worker_spaces_count}
};

ERL_NIF_INIT(edogstatsd_udp, edogstatsd_udp_nif_funcs, edogstatsd_udp_load,
             NULL, edogstatsd_udp_upgrade, edogstatsd_udp_unload)
